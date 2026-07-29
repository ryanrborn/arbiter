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
      override and the report **declines** a fleet-wide change.
    * Comparisons are grouped into `(difficulty, repo)` cells so drift with the
      difficulty/repo mix does not read as improvement.
  """

  alias Arbiter.Loop.{Corpus, FailureClassifier, Report}

  @small_sample_caveat "At ~15 dispatches/day most single-window deltas are not statistically significant — treat single-window movements as hypotheses, not results."

  # A fleet-wide change requires this much independent evidence. Anything less
  # is blast-radius-1: a per-task override, paper-trailed.
  @min_incidents 3
  @min_tasks 2

  @doc """
  Run the pass over a window: fetch, analyse, record own cost, return the
  report + rendered markdown.

  Options are passed to `Arbiter.Loop.Corpus.fetch/1` (`:since`, `:until`,
  `:limit`, `:label`). Returns `{:ok, %{report: %Report{}, markdown: String,
  usage_event_id: id | nil}}`.
  """
  @spec analyze(keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, rows, meta} <- Corpus.fetch(opts) do
      report = build_report(rows, Keyword.put(opts, :meta, meta))
      markdown = Report.to_markdown(report)
      duration_ms = System.monotonic_time(:millisecond) - started

      usage_event_id =
        if Keyword.get(opts, :record_cost?, true) do
          record_own_cost(duration_ms, length(rows), meta)
        end

      {:ok, %{report: report, markdown: markdown, usage_event_id: usage_event_id}}
    end
  end

  @doc """
  Build a `%Report{}` from already-fetched corpus rows. Pure — no I/O, no writes.
  """
  @spec build_report([map()], keyword()) :: Report.t()
  def build_report(rows, opts \\ []) do
    failed = Enum.filter(rows, &(&1.status == :failed))
    classified = Enum.map(failed, &classify_row/1)
    agent_quality = Enum.filter(classified, &(&1.classification.class == :agent_quality))

    finding_categories = finding_categories(agent_quality)

    # Difficulty/cost cells and misestimates are about the *authoring* work, so
    # they consider only main-worker runs — not the synthetic `#review`/`#impl`
    # runs (which carry no issue difficulty and would pollute the cells).
    main_rows = Enum.filter(rows, &(&1.worker_type == :main))
    misestimates = difficulty_misestimates(main_rows)

    %Report{
      window: window(opts),
      totals: totals(rows),
      segmentation: segmentation(classified),
      misclassification: misclassification(classified),
      finding_categories: finding_categories,
      difficulty_misestimates: misestimates,
      cells: cells(main_rows),
      suggestions: suggestions(finding_categories),
      notes: [@small_sample_caveat]
    }
  end

  # ---- classification -----------------------------------------------------

  defp classify_row(row) do
    Map.put(
      row,
      :classification,
      FailureClassifier.classify(row.failure_reason, row.terminal_lines)
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
    corroborated = Enum.filter(classified, & &1.classification.corroborated)
    reclassified = Enum.filter(corroborated, & &1.classification.reclassified)

    n_corr = length(corroborated)

    %{
      corroborated: n_corr,
      reclassified: length(reclassified),
      rate: if(n_corr == 0, do: 0.0, else: length(reclassified) / n_corr),
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

  # Keyword taxonomy over reviewer findings text. Order matters: first match
  # wins per finding string.
  @finding_buckets [
    {~r/inert|never (?:executed|called|invoked|run|wired)|not (?:wired|reachable)|green tests? but|passes? but .*runtime/i,
     "plausible code, green tests, inert at runtime"},
    {~r/no test|missing test|untested|test coverage|without a test/i, "missing test coverage"},
    {~r/secret|credential|token leaked/i, "secret / credential exposure"},
    {~r/regression|breaks? existing|broke /i, "regression in existing behaviour"}
  ]

  defp finding_categories(agent_quality_rows) do
    from_findings =
      agent_quality_rows
      |> Enum.flat_map(fn row ->
        row.findings
        |> Enum.map(&bucket_finding/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(fn {cat, example} -> {cat, row, example} end)
      end)

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

  defp bucket_finding(text) when is_binary(text) do
    Enum.find_value(@finding_buckets, fn {re, cat} ->
      if Regex.match?(re, text), do: {cat, text}
    end)
  end

  # ---- difficulty misestimates -------------------------------------------

  defp difficulty_misestimates(rows) do
    rows
    |> Enum.group_by(& &1.task_id)
    |> Enum.filter(fn {_task, task_rows} -> misestimate?(task_rows) end)
    |> Enum.map(fn {task_id, task_rows} ->
      dispatched =
        task_rows |> Enum.map(& &1.difficulty) |> Enum.reject(&is_nil/1) |> min_or_nil()

      rounds = task_rows |> Enum.map(& &1.max_round) |> Enum.max()
      cost = task_rows |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()
      repo = task_rows |> hd() |> Map.get(:repo)
      next = if dispatched, do: dispatched + 1, else: nil

      %{
        task_id: task_id,
        cell: {dispatched, repo},
        dispatched_difficulty: dispatched,
        rounds: rounds,
        cost_usd: cost,
        note:
          "Dispatched difficulty #{inspect(dispatched)} under-provisioned the actual work: #{rounds} review round(s), $#{fmt(cost)} across #{length(task_rows)} attempt(s). Segmented within cell (#{inspect(dispatched)}, #{repo}).",
        recommendation: %{
          destination: :per_task_override,
          action:
            "paper-trailed per-task override (blast-radius 1): set Issue.difficulty=#{inspect(next)} on #{task_id} and log a tracked hypothesis — do NOT change fleet routing on this single case",
          target_metric: "round-1 approval rate for #{task_id}",
          baseline: "0% (first attempt needed #{rounds} rounds)"
        }
      }
    end)
    |> Enum.sort_by(& &1.task_id)
  end

  # A task mispredicts difficulty when it needed rework (round >= 2) or was
  # rejected/failed on *work quality* — the dispatched difficulty under-provisioned
  # the cost/rounds actually incurred.
  #
  # Context-exhaustion is deliberately EXCLUDED: per the worked example in the
  # ticket, an agent burning its own context window is a read-discipline
  # problem, not a difficulty misestimate. It is surfaced separately as its own
  # finding category. Conflating the two would (wrongly) recommend raising the
  # difficulty of every context-death task.
  defp misestimate?(task_rows) do
    reworked? = Enum.any?(task_rows, &(&1.max_round >= 2))

    quality_failure? =
      Enum.any?(task_rows, fn r ->
        r.status == :failed and
          quality_misestimate_signal?(
            FailureClassifier.classify(r.failure_reason, r.terminal_lines)
          )
      end)

    has_difficulty? = Enum.any?(task_rows, &(not is_nil(&1.difficulty)))

    (reworked? or quality_failure?) and has_difficulty?
  end

  # Agent-quality failures that point at *difficulty* (the work was harder than
  # provisioned), excluding context-exhaustion (a read-discipline signal).
  defp quality_misestimate_signal?(%{class: :agent_quality, subcategory: sub}),
    do: sub != :context_exhaustion

  defp quality_misestimate_signal?(_), do: false

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
        cost: task_rows |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum(),
        reworked?: Enum.any?(task_rows, &(&1.max_round >= 2))
      }
    end)
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
        mean_cost_usd: total_cost / n
      }
    end)
    |> Enum.sort_by(&{&1.repo, &1.difficulty})
  end

  # ---- suggestions + evidence bar ----------------------------------------

  defp suggestions(finding_categories) do
    Enum.map(finding_categories, fn cat ->
      incidents = cat.incidents
      tasks = length(cat.tasks)
      fleet? = incidents >= @min_incidents and tasks >= @min_tasks
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
              "#{incidents} incidents across #{tasks} tasks clears the ≥ #{@min_incidents} incidents / ≥ #{@min_tasks} tasks evidence bar.",
            else:
              "n=#{incidents} across #{tasks} task(s) is below the ≥ #{@min_incidents} incidents / ≥ #{@min_tasks} tasks bar — decline a fleet-wide change; take a per-task override + tracked hypothesis instead."
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
