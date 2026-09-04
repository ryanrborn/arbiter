defmodule Arbiter.Loop.Analysis do
  @moduledoc """
  The Stage 1 loop-analysis pass (bd-dyfaq3): turn a window of enriched
  `worker_runs` into an operator-facing `Arbiter.Loop.Report`, and record the
  pass's own cost in the ledger it is optimising.

  `build_report/2` is the pure core — it reasons over already-fetched corpus
  rows and writes nothing. `analyze/1` is the shell: it fetches the window via
  `Arbiter.Loop.Corpus`, builds the report, and records a single
  `usage_events` row for the pass itself (the only write the pass performs — it
  edits no skills, config, or task overrides).

  ## Discipline encoded here

    * Failures are segmented operational vs agent-quality by allowlist
      (`Arbiter.Loop.FailureClassifier`); operational reasons are excluded from
      every prompt-shaping output.
    * `failure_reason` is corroborated against the transcript; the
      label↔transcript disagreement rate is a first-class finding.
    * The **evidence bar** for a fleet-wide suggestion is ≥ 3 incidents across
      ≥ 2 distinct tasks. Below it, a finding becomes a paper-trailed per-task
      override and the report **declines** a fleet-wide change. The thresholds
      default to those constants and are overridable per workspace under
      `loop.evidence_bar.{min_incidents,min_distinct_tasks}` (bd-9j2g3x).
    * Comparisons are grouped into `(difficulty, repo)` cells so drift with the
      difficulty/repo mix does not read as improvement.
    * The **objective function** is denominated in the unit that actually binds
      (#1463, Amendment E). Under subscription billing that is
      `window_share_5h` — a task's draw on the 5-hour utilization window, the
      window `Arbiter.Quota.Gate` throttles on — with imputed dollars retained
      as a secondary figure. Under metered API billing dollars still bind and
      stay primary. `Arbiter.Loop.Scarcity` owns the decision and its reasoning;
      `Arbiter.Loop.Corpus` supplies the calibration on `meta.scarcity`.
  """

  alias Arbiter.Loop.{Corpus, FailureClassifier, FindingBuckets, Proposals, Report, Scarcity}

  @small_sample_caveat "At ~15 dispatches/day most single-window deltas are not statistically significant — treat single-window movements as hypotheses, not results."

  # A fleet-wide change requires this much independent evidence. Anything less
  # is blast-radius-1: a per-task override, paper-trailed. These are the
  # defaults; a workspace may raise or lower them under
  # `loop.evidence_bar.{min_incidents,min_distinct_tasks}` (bd-9j2g3x), which is
  # why the bar is threaded through as a value rather than read from here.
  @min_incidents 3
  @min_tasks 2

  # For cohort-based comparisons (rework and quality_failure signals), require
  # a minimum sample size. With fewer peers, the computed median is not a
  # reliable ground truth for comparison. Below this threshold, treat it as
  # insufficient evidence (flag with nil cohort stats), matching the empty-cohort
  # behavior — this avoids the "silent divide-by-small-n" anti-pattern where a
  # single peer task's value is treated as a cell-wide signal.
  @min_cohort_size 2

  @doc """
  Run the pass over a window: fetch, analyse, record own cost, return the
  report + rendered markdown.

  Options are passed to `Arbiter.Loop.Corpus.fetch/1` (`:since`, `:until`,
  `:limit`, `:label`). Returns `{:ok, %{report: %Report{}, markdown: String,
  usage_event_id: id | nil}}`.

  ## `propose?: true` (opt-in, bd-9j2g3x)

  Off by default, and the default path is **byte-identical** to before Stage 2:
  the pass still writes nothing but its own cost row. Opted in, each suggestion
  is additionally persisted as an `Arbiter.Loop.PendingWrite` — inserted, or
  reinforced onto the row with the same fingerprint from an earlier window — and
  the returned map gains a `:proposals` key. Proposals are inert: queueing one
  applies nothing, at any evidence level.

  A candidate `Arbiter.Loop.record/2` refuses (e.g. a `:fleet` candidate on
  an install with no unambiguous default workspace, bd-3dasqm) is not queued
  and is not silently lost either: it is counted in `:proposals_dropped`
  (`[%{gist:, reason:}]`) so an operator on such an install can see the
  fleet-finding stream is going missing, rather than only a log line.
  """
  @spec analyze(keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, rows, meta} <- Corpus.fetch(opts) do
      workspace_id = Keyword.get(opts, :workspace_id) || Map.get(meta, :workspace_id)

      report =
        rows
        |> build_report(
          opts
          |> Keyword.put(:meta, meta)
          |> Keyword.put_new_lazy(:evidence_bar, fn -> Arbiter.Loop.evidence_bar(workspace_id) end)
        )
        |> add_zero_token_notes(meta)

      markdown = Report.to_markdown(report)
      duration_ms = System.monotonic_time(:millisecond) - started

      usage_event_id =
        if Keyword.get(opts, :record_cost?, true) do
          record_own_cost(duration_ms, length(rows), meta)
        end

      envelope = %{report: report, markdown: markdown, usage_event_id: usage_event_id}

      # `:proposals` is only added when the caller opted in, so a non-proposing
      # caller sees exactly the map shape it saw before Stage 2.
      if Keyword.get(opts, :propose?, false) do
        %{rows: proposals, dropped: dropped} =
          Proposals.record_all(report,
            workspace_id: workspace_id,
            actor: Keyword.get(opts, :actor, "loop")
          )

        envelope =
          envelope
          |> Map.put(:proposals, proposals)
          |> Map.put(:proposals_dropped, dropped)

        {:ok, envelope}
      else
        {:ok, envelope}
      end
    end
  end

  @doc """
  Build a `%Report{}` from already-fetched corpus rows. Pure — no I/O, no writes.

  `:evidence_bar` overrides the fleet-wide bar (a
  `%{min_incidents: _, min_distinct_tasks: _}` map); it defaults to the
  documented `≥ #{@min_incidents}` incidents / `≥ #{@min_tasks}` tasks.
  """
  @spec build_report([map()], keyword()) :: Report.t()
  def build_report(rows, opts \\ []) do
    scarcity = scarcity(opts)
    failed = Enum.filter(rows, &(&1.status == :failed))
    classified = Enum.map(failed, &classify_row/1)
    agent_quality = Enum.filter(classified, &(&1.classification.class == :agent_quality))

    finding_categories = finding_categories(agent_quality)

    # Difficulty/cost cells and misestimates are about the *authoring* work, so
    # they consider only main-worker runs — not the synthetic `#review`/`#impl`
    # runs (which carry no issue difficulty and would pollute the cells).
    main_rows = Enum.filter(rows, &(&1.worker_type == :main))
    misestimates = difficulty_misestimates(main_rows, scarcity)

    %Report{
      window: window(opts),
      totals: totals(rows),
      scarcity: scarcity,
      segmentation: segmentation(classified),
      misclassification: misclassification(classified),
      finding_categories: finding_categories,
      difficulty_misestimates: misestimates,
      cells: cells(main_rows),
      suggestions: suggestions(finding_categories, evidence_bar(opts)),
      finding_residue: finding_residue(opts),
      notes: [@small_sample_caveat, own_draw_note()]
    }
  end

  # The scarcity frame `Arbiter.Loop.Corpus.fetch/1` computed for this window.
  # `build_report/2` is called directly (tests, and any caller assembling rows
  # by hand), so a missing frame degrades to metered/uncalibrated — the same
  # unit the pass used before #1463 — rather than crashing or inventing a
  # calibration.
  defp scarcity(opts) do
    case opts |> Keyword.get(:meta, %{}) |> Map.get(:scarcity) do
      %{unit: unit, calibration: _} = frame when unit in [:window_share_5h, :cost_usd] ->
        frame

      _ ->
        mode = {:metered, :default}

        %{
          unit: Scarcity.primary_metric(mode),
          secondary_unit: Scarcity.secondary_metric(mode),
          billing_mode: mode,
          calibration: Scarcity.calibrate(0.0, nil)
        }
    end
  end

  # Amendment E's own footnote: an analyser that measures quota windows must
  # account for the windows it consumes. Stage 1 is deterministic Elixir with
  # no model call, so its draw is a measured zero (written explicitly onto the
  # pass's `usage_events` row by `Corpus.record_pass_cost/1`). This note is the
  # place that claim stops being true the moment an LLM call lands inside
  # `Loop` — the payload-authoring work — so it is rendered every window
  # rather than left to the design doc.
  defp own_draw_note do
    "Analyser's own draw on the quota windows it measures: none — the Stage 1 pass is deterministic Elixir and makes no model call, so its `usage_events` row carries an explicit zero-token draw. If an LLM call ever lands inside `Loop`, its draw lands on that row and this note must stop saying \"none\"."
  end

  # `Corpus.fetch/1` computes the residue (it owns the raw `review_gate_rounds`
  # query, over ALL review rounds in the window — not just the agent-quality
  # subset `finding_categories/1` clusters) and carries it in `meta`, alongside
  # `failed_runs` / `transcript_reads`. This just threads it onto the report.
  defp finding_residue(opts) do
    opts |> Keyword.get(:meta, %{}) |> Map.get(:finding_residue, Corpus.empty_finding_residue())
  end

  # ---- classification -----------------------------------------------------

  defp classify_row(row) do
    Map.put(row, :classification, classification_for(row))
  end

  # bd-apwfmy: prefer the run's typed `stop_category` (structured, recorded at
  # the moment of death) over the transcript scan. `Map.get/3` rather than a
  # struct field — a corpus row assembled before the column existed simply
  # carries no key, and the classifier ignores a nil category.
  defp classification_for(row) do
    FailureClassifier.classify(row.failure_reason, row.terminal_lines,
      stop_category: Map.get(row, :stop_category)
    )
  end

  defp segmentation(classified) do
    classified
    |> Enum.group_by(fn c -> {c.classification.class, c.classification.subcategory} end)
    |> Enum.map(fn {{class, sub}, rows} ->
      %{class: class, subcategory: sub, count: length(rows), run_ids: Enum.map(rows, & &1.run_id)}
    end)
    |> Enum.sort_by(&{class_rank(&1.class), -&1.count})
  end

  defp class_rank(:agent_quality), do: 0
  defp class_rank(:operational), do: 1
  defp class_rank(:unknown), do: 2
  defp class_rank(:excluded), do: 3
  defp class_rank(_), do: 4

  defp misclassification(classified) do
    # Only an *operational* label can be "hiding" an agent-quality failure
    # behind ops noise (the c88c77b0 case: labelled rate-limited, actually
    # context exhaustion). Agent-quality-labelled runs also carry transcripts,
    # so including them in the denominator would dilute the true
    # operational-mislabel rate — on the real corpus `:review_gate_rejected`
    # failures dominate and would understate the signal by a large factor.
    # Restrict the denominator to operational labels; the numerator is the
    # subset of those that the transcript flipped to agent-quality.
    corroborated =
      Enum.filter(
        classified,
        &(&1.classification.corroborated and &1.classification.label_class == :operational)
      )

    reclassified = Enum.filter(corroborated, & &1.classification.reclassified)

    n_corr = length(corroborated)

    %{
      corroborated: n_corr,
      reclassified: length(reclassified),
      rate: if(n_corr == 0, do: nil, else: length(reclassified) / n_corr),
      citations:
        Enum.map(reclassified, fn c ->
          %{
            run_id: c.run_id,
            failure_reason: c.failure_reason,
            corrected: c.classification.subcategory
          }
        end)
    }
  end

  # ---- finding categories (cluster reviewer findings + failure subcats) ----

  defp finding_categories(agent_quality_rows) do
    # Reviewer findings are task-level: `Corpus` keys the same `findings` list
    # to every run of a task (review rounds are recorded under the base task
    # id, not a run id). Counting per-row would therefore count each finding
    # once per failed agent-quality *run* of the task — inflating `incidents`
    # for any task with more than one such run. Dedupe to one entry per
    # `(category, task)` so a task's finding is counted once per task.
    #
    # Context-exhaustion (`from_context` below) is deliberately NOT deduped:
    # it is a per-run death detected from that run's own transcript, so two
    # context deaths in one task are two genuine incidents.
    from_findings =
      agent_quality_rows
      |> Enum.flat_map(fn row ->
        row.findings
        |> Enum.map(&FindingBuckets.bucket_finding/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(fn {cat, example} -> {cat, row, example} end)
      end)
      |> Enum.uniq_by(fn {cat, row, _ex} -> {cat, row.task_id} end)

    from_context =
      agent_quality_rows
      |> Enum.filter(&(&1.classification.subcategory == :context_exhaustion))
      |> Enum.map(fn row ->
        {"context exhaustion — agent burned its own context window (no read discipline)", row,
         "autocompact thrash / claude session error with no API error"}
      end)

    (from_findings ++ from_context)
    |> Enum.group_by(fn {cat, _row, _ex} -> cat end)
    |> Enum.map(fn {cat, entries} ->
      rows = Enum.map(entries, fn {_c, row, _e} -> row end)

      %{
        category: cat,
        incidents: length(rows),
        tasks: rows |> Enum.map(& &1.task_id) |> Enum.uniq(),
        run_ids: rows |> Enum.map(& &1.run_id) |> Enum.uniq(),
        example: entries |> hd() |> elem(2)
      }
    end)
    |> Enum.sort_by(&(-&1.incidents))
  end

  # ---- difficulty misestimates -------------------------------------------

  # Two distinct signals can indicate a difficulty misestimate, and they are
  # NOT the same claim:
  #
  #   :rework — the task needed a second review round. This alone means the
  #     dispatched difficulty under-provisioned the work; round-1 approval
  #     genuinely failed, so a "0%" round-1-approval baseline is true.
  #
  #   :quality_failure — every review round converged on round 1, but one or
  #     more *attempts* failed for an agent-quality reason before the task
  #     converged (vs-8i7rod: rounds: 1, 3 attempts, $5.59). This is a cost
  #     signal, not evidence the reviewer under-provisioned rounds — reusing
  #     the rework wording/baseline here is what over-fired 16/133 tasks.
  #
  # Context-exhaustion is deliberately EXCLUDED from quality_failure?: per the
  # worked example in the ticket, an agent burning its own context window is a
  # read-discipline problem, not a difficulty misestimate. It is surfaced
  # separately as its own finding category.
  #
  # Both signals are then filtered against the task's own (difficulty, repo)
  # cohort: a task no worse than its cell peers on cost and rounds is dropped,
  # per the ticket's "compare within a cell" discipline. A task with no cohort
  # data this window (nothing else in its cell) can't be shown to be an
  # outlier, so it is flagged by default rather than silently dropped.
  defp difficulty_misestimates(rows, scarcity) do
    tasks = task_level(rows)
    cells = Enum.group_by(tasks, &{&1.difficulty, &1.repo})

    tasks
    |> Enum.filter(&(&1.has_difficulty? and (&1.reworked? or &1.quality_failure?)))
    |> Enum.map(&build_misestimate(&1, cells, scarcity))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.task_id)
  end

  defp task_level(rows) do
    rows
    |> Enum.group_by(& &1.task_id)
    |> Enum.map(fn {task_id, task_rows} ->
      dispatched =
        task_rows |> Enum.map(& &1.difficulty) |> Enum.reject(&is_nil/1) |> min_or_nil()

      rounds = task_rows |> Enum.map(& &1.max_round) |> Enum.max()
      cost = task_rows |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()
      repo = task_rows |> hd() |> Map.get(:repo)

      quality_failure? =
        Enum.any?(task_rows, fn r ->
          r.status == :failed and
            quality_misestimate_signal?(classification_for(r))
        end)

      %{
        task_id: task_id,
        difficulty: dispatched,
        repo: repo,
        cost: cost,
        window_share: sum_shares(task_rows),
        rounds: rounds,
        attempts: length(task_rows),
        reworked?: rounds >= 2,
        quality_failure?: quality_failure?,
        has_difficulty?: Enum.any?(task_rows, &(not is_nil(&1.difficulty)))
      }
    end)
  end

  # Agent-quality failures that point at *difficulty* (the work was harder than
  # provisioned), excluding context-exhaustion (a read-discipline signal).
  defp quality_misestimate_signal?(%{class: :agent_quality, subcategory: sub}),
    do: sub != :context_exhaustion

  defp quality_misestimate_signal?(_), do: false

  defp build_misestimate(t, cells, scarcity) do
    cohort =
      cells
      |> Map.get({t.difficulty, t.repo}, [])
      |> Enum.reject(&(&1.task_id == t.task_id))

    reason = if t.reworked?, do: :rework, else: :quality_failure

    case cohort_verdict(cohort, t, reason, scarcity) do
      :drop ->
        nil

      {:flag, cohort_stats} ->
        %{
          task_id: t.task_id,
          cell: {t.difficulty, t.repo},
          dispatched_difficulty: t.difficulty,
          rounds: t.rounds,
          cost_usd: t.cost,
          window_share_5h: t.window_share,
          reason: reason,
          note: misestimate_note(reason, t, cohort_stats),
          recommendation: misestimate_recommendation(reason, t, cohort_stats)
        }
    end
  end

  # Which unit this particular comparison runs in. `:window_share_5h` only when
  # the installation's binding unit *is* the window AND the subject and every
  # peer carries a share — a cell where only some tasks have one would silently
  # mix units. Otherwise `:cost_usd`, which is what the comparison used before
  # #1463 and what still binds under metered billing.
  defp comparison_unit(subject, cohort, %{unit: :window_share_5h}) do
    if Enum.all?([subject | cohort], &is_number(&1.window_share)),
      do: :window_share_5h,
      else: :cost_usd
  end

  defp comparison_unit(_subject, _cohort, _scarcity), do: :cost_usd

  defp draw(t, :window_share_5h), do: t.window_share
  defp draw(t, :cost_usd), do: t.cost

  # Render a draw in whichever unit the comparison ran in, so a note and its
  # baseline can never disagree about what they are counting. The subject's own
  # draw is spelled out in full ("49.4% of one 5h window"); a cohort median
  # appearing beside it is compact ("0.3%"), which reads as English rather than
  # repeating the unit inside a noun phrase.
  defp fmt_draw(nil, _unit), do: "n/a"
  defp fmt_draw(value, :window_share_5h), do: Scarcity.format_share(value)
  defp fmt_draw(value, :cost_usd), do: "$#{fmt(value)}"

  defp fmt_median(nil, _unit), do: "n/a"

  defp fmt_median(value, :window_share_5h),
    do: "#{:erlang.float_to_binary(value * 100, decimals: 1)}%"

  defp fmt_median(value, :cost_usd), do: "$#{fmt(value)}"

  # A task's total draw is the sum of its runs' shares. `nil` when no run
  # carries one — the corpus could not calibrate the window, and summing
  # nothing into `0.0` would claim a measurement that was never taken.
  defp sum_shares(task_rows) do
    shares = task_rows |> Enum.map(&Map.get(&1, :window_share_5h)) |> Enum.filter(&is_number/1)
    if shares == [], do: nil, else: Enum.sum(shares)
  end

  defp sum_group_shares(group) do
    shares = group |> Enum.map(& &1.window_share) |> Enum.filter(&is_number/1)
    if shares == [], do: nil, else: Enum.sum(shares)
  end

  defp mean_share(tasks) do
    shares = tasks |> Enum.map(& &1.window_share) |> Enum.filter(&is_number/1)
    if shares == [], do: nil, else: Enum.sum(shares) / length(shares)
  end

  # No cohort data this window means there is nothing to compare against, so
  # we can't demonstrate the task is (or isn't) an outlier — flag it rather
  # than silently drop it on an absence of evidence.
  defp cohort_verdict([], t, _reason, scarcity),
    do: {:flag, %{draw: nil, rounds: nil, unit: comparison_unit(t, [], scarcity)}}

  # Cohort too small to have a meaningful median: treat as insufficient evidence
  # (same path as empty cohort). This avoids computing a "median" from a single
  # peer task and treating it as reliable ground truth.
  defp cohort_verdict(cohort, t, _reason, scarcity) when length(cohort) < @min_cohort_size do
    {:flag, %{draw: nil, rounds: nil, unit: comparison_unit(t, cohort, scarcity)}}
  end

  # For rework cases (multiple review rounds), require the task to exceed its
  # cell median on BOTH rounds and draw. This filters out tasks that needed
  # rework but didn't draw more (true rework, not under-provisioning).
  #
  # #1463: "draw" is the binding unit, not necessarily dollars. Under
  # subscription billing a task that is *cheaper* in imputed dollars than its
  # peers but eats more of the 5h window is exactly the case the old
  # cost-denominated comparison could not see.
  defp cohort_verdict(cohort, t, :rework, scarcity) do
    unit = comparison_unit(t, cohort, scarcity)
    cohort_draw = cohort |> Enum.map(&draw(&1, unit)) |> median()
    cohort_rounds = cohort |> Enum.map(& &1.rounds) |> median()

    if draw(t, unit) > cohort_draw and t.rounds > cohort_rounds do
      {:flag, %{draw: cohort_draw, rounds: cohort_rounds, unit: unit}}
    else
      :drop
    end
  end

  # For quality_failure cases (agent failures), require the task to exceed its
  # cell median on draw only. Rounds are not the signal for quality failures
  # (they converge in round 1 by definition), so we only care if the draw is
  # anomalously high.
  defp cohort_verdict(cohort, t, :quality_failure, scarcity) do
    unit = comparison_unit(t, cohort, scarcity)
    cohort_draw = cohort |> Enum.map(&draw(&1, unit)) |> median()
    cohort_rounds = cohort |> Enum.map(& &1.rounds) |> median()

    if draw(t, unit) > cohort_draw do
      {:flag, %{draw: cohort_draw, rounds: cohort_rounds, unit: unit}}
    else
      :drop
    end
  end

  defp misestimate_note(:rework, t, %{draw: nil, unit: unit}) do
    "Dispatched difficulty #{inspect(t.difficulty)} under-provisioned the actual work: " <>
      "#{t.rounds} review round(s), #{fmt_draw(draw(t, unit), unit)} across #{t.attempts} attempt(s) " <>
      "(no cohort data this window to compare against). Segmented within cell " <>
      "(#{inspect(t.difficulty)}, #{t.repo})."
  end

  defp misestimate_note(:rework, t, %{draw: cohort_draw, rounds: cohort_rounds, unit: unit}) do
    "Dispatched difficulty #{inspect(t.difficulty)} under-provisioned the actual work: " <>
      "#{t.rounds} review round(s) (cell median #{cohort_rounds}), #{fmt_draw(draw(t, unit), unit)} across " <>
      "#{t.attempts} attempt(s) (cell median #{fmt_median(cohort_draw, unit)}). Segmented within cell " <>
      "(#{inspect(t.difficulty)}, #{t.repo})."
  end

  defp misestimate_note(:quality_failure, t, %{draw: nil, unit: unit}) do
    "Converged in round 1, but needed #{t.attempts} attempt(s) due to agent-quality " <>
      "failures on the way there: #{fmt_draw(draw(t, unit), unit)} total (no cohort data this window to " <>
      "compare against). This is a #{unit_word(unit)} signal, not a rounds-based under-provisioning " <>
      "claim. Segmented within cell (#{inspect(t.difficulty)}, #{t.repo})."
  end

  defp misestimate_note(:quality_failure, t, %{draw: cohort_draw, unit: unit}) do
    "Converged in round 1, but needed #{t.attempts} attempt(s) due to agent-quality " <>
      "failures on the way there: #{fmt_draw(draw(t, unit), unit)} total vs. a #{fmt_median(cohort_draw, unit)} cell " <>
      "median. This is a #{unit_word(unit)} signal, not a rounds-based under-provisioning claim. " <>
      "Segmented within cell (#{inspect(t.difficulty)}, #{t.repo})."
  end

  # The `:rework` misestimate is the one that becomes a real proposal — a
  # `:difficulty_override` `PendingWrite` carrying this exact `target_metric` /
  # `baseline` pair as its pre-registration (see `Arbiter.Loop.Proposals`).
  # Under subscription billing it is therefore the proposal kind that is
  # denominated in the binding unit: the metric to move is the task's draw on
  # the 5h window, with round-1 approval retained in the baseline as the
  # leading indicator it has always been.
  defp misestimate_recommendation(:rework, t, %{unit: :window_share_5h} = cs) do
    %{
      destination: :per_task_override,
      action: rework_action(t),
      target_metric: "5h-window share to converge for #{t.task_id}",
      baseline:
        "#{Scarcity.format_share(t.window_share)} across #{t.attempts} attempt(s)" <>
          cohort_clause(cs) <>
          "; round-1 approval 0% (first attempt needed #{t.rounds} rounds)"
    }
  end

  defp misestimate_recommendation(:rework, t, _cohort_stats) do
    %{
      destination: :per_task_override,
      action: rework_action(t),
      target_metric: "round-1 approval rate for #{t.task_id}",
      baseline: "0% (first attempt needed #{t.rounds} rounds)"
    }
  end

  defp misestimate_recommendation(:quality_failure, t, %{draw: nil, unit: unit}) do
    %{
      destination: :per_task_override,
      action: quality_failure_action(t, unit),
      target_metric: "#{unit_metric(unit)} to converge for #{t.task_id}",
      baseline:
        "#{fmt_draw(draw(t, unit), unit)} across #{t.attempts} attempt(s) (no cohort baseline available)"
    }
  end

  defp misestimate_recommendation(:quality_failure, t, %{draw: cohort_draw, unit: unit}) do
    %{
      destination: :per_task_override,
      action: quality_failure_action(t, unit),
      target_metric: "#{unit_metric(unit)} to converge for #{t.task_id}",
      baseline:
        "#{fmt_draw(draw(t, unit), unit)} across #{t.attempts} attempt(s), vs. #{fmt_median(cohort_draw, unit)} cell median"
    }
  end

  defp rework_action(t) do
    next = if t.difficulty, do: t.difficulty + 1, else: nil

    "paper-trailed per-task override (blast-radius 1): set Issue.difficulty=#{inspect(next)} on #{t.task_id} and log a tracked hypothesis — do NOT change fleet routing on this single case"
  end

  defp quality_failure_action(t, unit) do
    "paper-trailed per-task override (blast-radius 1): investigate the agent-quality failures on #{t.task_id}'s earlier attempts before recommending a difficulty change — the reviewer approved on round 1, so this is a #{unit_word(unit)} anomaly, not a rounds signal"
  end

  defp cohort_clause(%{draw: nil}), do: " (no cohort baseline available)"

  defp cohort_clause(%{draw: cohort_draw, unit: unit}),
    do: ", vs. a #{fmt_median(cohort_draw, unit)} cell median"

  defp unit_word(:window_share_5h), do: "quota-window"
  defp unit_word(:cost_usd), do: "cost"

  defp unit_metric(:window_share_5h), do: "5h-window share"
  defp unit_metric(:cost_usd), do: "cost"

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # ---- (difficulty, repo) cells ------------------------------------------

  defp cells(rows) do
    rows
    |> Enum.group_by(& &1.task_id)
    |> Enum.map(fn {_task, task_rows} ->
      first = hd(task_rows)

      difficulty =
        task_rows |> Enum.map(& &1.difficulty) |> Enum.reject(&is_nil/1) |> min_or_nil()

      %{
        task_id: first.task_id,
        difficulty: difficulty,
        repo: first.repo,
        title: Map.get(first, :title),
        cost: task_rows |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum(),
        window_share: sum_shares(task_rows),
        reworked?: Enum.any?(task_rows, &(&1.max_round >= 2))
      }
    end)
    |> collapse_duplicate_dispatches()
    |> Enum.group_by(&{&1.difficulty, &1.repo})
    |> Enum.map(fn {{difficulty, repo}, tasks} ->
      n = length(tasks)
      reworked = Enum.count(tasks, & &1.reworked?)
      total_cost = tasks |> Enum.map(& &1.cost) |> Enum.sum()

      %{
        difficulty: difficulty,
        repo: repo,
        tasks: n,
        rework_rate: reworked / n,
        # `nil` — not `0.0` — when no task in the cell carries a share: an
        # uncalibrated window must not read as a cell that draws nothing.
        mean_window_share_5h: mean_share(tasks),
        mean_cost_usd: total_cost / n
      }
    end)
    |> Enum.sort_by(&{&1.repo, &1.difficulty})
  end

  # #1221: the same unit of work re-filed as N separate tasks (same repo, same
  # title/target signature) must not read as N independent clean successes —
  # each near-duplicate group collapses to a single unit whose cost is the sum
  # across the group (not diluted by the inflated denominator) and which is
  # itself treated as reworked (N re-filings for one unit of work is the
  # pathology this cell exists to catch, not a healthy 0%-rework signal).
  defp collapse_duplicate_dispatches(tasks) do
    tasks
    |> Enum.group_by(&{&1.repo, duplicate_signature(&1.title)})
    |> Enum.flat_map(fn
      {{_repo, nil}, group} ->
        group

      {_key, [single]} ->
        [single]

      {{repo, _sig}, group} ->
        [
          %{
            task_id: group |> Enum.map_join("+", & &1.task_id),
            difficulty:
              group |> Enum.map(& &1.difficulty) |> Enum.reject(&is_nil/1) |> min_or_nil(),
            repo: repo,
            title: hd(group).title,
            cost: group |> Enum.map(& &1.cost) |> Enum.sum(),
            window_share: sum_group_shares(group),
            reworked?: true
          }
        ]
    end)
  end

  # A duplicate-dispatch signature: tasks filed against the same PR/MR ref are
  # the same referent regardless of any incidental title drift; otherwise fall
  # back to the trimmed title itself. `nil`/blank titles never cluster — there
  # is no signature to match on, so each such task stays its own unit.
  defp duplicate_signature(nil), do: nil

  defp duplicate_signature(title) when is_binary(title) do
    case Regex.run(~r/^PR #(\d+)/i, title) do
      [_, num] ->
        {:pr, num}

      _ ->
        case String.trim(title) do
          "" -> nil
          trimmed -> {:title, trimmed}
        end
    end
  end

  # ---- suggestions + evidence bar ----------------------------------------

  # The effective bar for this pass: the caller's `:evidence_bar` (resolved from
  # workspace config by `analyze/1`) or the documented defaults.
  defp evidence_bar(opts) do
    case Keyword.get(opts, :evidence_bar) do
      %{min_incidents: i, min_distinct_tasks: t} when is_integer(i) and is_integer(t) ->
        %{min_incidents: i, min_distinct_tasks: t}

      _ ->
        %{min_incidents: @min_incidents, min_distinct_tasks: @min_tasks}
    end
  end

  defp suggestions(finding_categories, bar) do
    Enum.map(finding_categories, fn cat ->
      incidents = cat.incidents
      tasks = length(cat.tasks)
      fleet? = incidents >= bar.min_incidents and tasks >= bar.min_distinct_tasks
      {destination, target_metric, baseline} = suggestion_targets(cat, fleet?)

      %{
        title: cat.category,
        target_metric: target_metric,
        baseline: baseline,
        destination: destination,
        evidence: %{incidents: incidents, tasks: tasks},
        verdict: if(fleet?, do: :fleet_wide, else: :per_task_override),
        rationale:
          if(fleet?,
            do:
              "#{incidents} incidents across #{tasks} tasks clears the ≥ #{bar.min_incidents} incidents / ≥ #{bar.min_distinct_tasks} tasks evidence bar.",
            else:
              "n=#{incidents} across #{tasks} task(s) is below the ≥ #{bar.min_incidents} incidents / ≥ #{bar.min_distinct_tasks} tasks bar — decline a fleet-wide change; take a per-task override + tracked hypothesis instead."
          )
      }
    end)
  end

  # Destination heuristic: a general working practice (read discipline, verify
  # at runtime) belongs in a skill; a repo-specific convention in that repo's
  # CLAUDE.md; a single incident in a per-task override.
  defp suggestion_targets(cat, fleet?) do
    cond do
      not fleet? ->
        {:per_task_override, "round-1 approval rate for the affected task",
         "first attempt needed rework"}

      cat.category =~ "context exhaustion" ->
        {:skill, "context-exhaustion failures per week", "#{cat.incidents} this window"}

      cat.category =~ "inert at runtime" ->
        {:skill, "round-1 approval rate on affected cell",
         "#{cat.incidents} inert-at-runtime rejections this window"}

      true ->
        {:skill, "rework rate (round ≥ 2)", "#{cat.incidents} incidents this window"}
    end
  end

  # ---- own cost -----------------------------------------------------------

  defp record_own_cost(duration_ms, rows_scanned, meta) do
    Corpus.record_pass_cost(%{
      duration_ms: duration_ms,
      rows_scanned: rows_scanned,
      workspace_id: Map.get(meta || %{}, :workspace_id)
    })
  end

  # ---- misc ---------------------------------------------------------------

  # bd-2fzwlc: a provider whose stream parser silently drops usage (exactly
  # what happened to every Gemini/agy row before this fix) reads identically
  # to "that provider is just cheap" unless the report calls it out. Impure
  # (queries `Arbiter.Usage` directly) — deliberately kept out of
  # `build_report/2` so that function stays a pure, DB-free formatter.
  defp add_zero_token_notes(%Report{} = report, meta) do
    usage_opts =
      [
        since: Map.get(meta, :since),
        until: Map.get(meta, :until),
        workspace_id: Map.get(meta, :workspace_id)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Arbiter.Usage.zero_token_providers(usage_opts) do
      {:ok, []} ->
        report

      {:ok, flagged} ->
        notes = Enum.map(flagged, &zero_token_note/1)
        %{report | notes: report.notes ++ notes}
    end
  end

  defp zero_token_note(%{provider: provider, rows: rows}) do
    "⚠ **#{provider}**: all #{rows} usage_events row(s) this window carry zero tokens — " <>
      "this reads as \"#{provider} is cheap\" but more likely means its stream parser is " <>
      "silently dropping usage. Verify empirically before trusting this provider's spend numbers."
  end

  defp window(opts) do
    meta = Keyword.get(opts, :meta, %{})

    %{
      label: Keyword.get(opts, :label) || Map.get(meta, :label) || "the analysis window",
      since: Map.get(meta, :since),
      until: Map.get(meta, :until)
    }
  end

  defp totals(rows) do
    %{
      runs: length(rows),
      main_runs: Enum.count(rows, &(&1.worker_type == :main)),
      dispatches: Enum.count(rows, &(&1.worker_type == :main)),
      failed: Enum.count(rows, &(&1.status == :failed)),
      completed: Enum.count(rows, &(&1.status == :completed)),
      tasks: rows |> Enum.map(& &1.task_id) |> Enum.uniq() |> length()
    }
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(list), do: Enum.min(list)

  defp fmt(nil), do: "0.00"
  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
