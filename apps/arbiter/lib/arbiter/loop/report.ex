defmodule Arbiter.Loop.Report do
  @moduledoc """
  The data contract + markdown renderer for the Stage 1 loop-analysis pass
  (bd-dyfaq3, epic #1011).

  `Arbiter.Loop.Analysis` computes every number and packs it into a `%Report{}`;
  `to_markdown/1` is a pure formatter with no database or I/O, so the exact
  markdown the operator reads is testable in isolation. Keeping the struct
  separate from the analysis means the discipline the report must enforce lives
  in one inspectable shape:

    * `segmentation` — operational vs agent-quality counts, with `run_ids` so
      every claim is cited. Operational is shown but flagged excluded from
      prompt-shaping.
    * `misclassification` — the rate at which `failure_reason` disagreed with
      the transcript, a **first-class corpus-integrity finding**, with the
      corrected run_ids (the c88c77b0 lesson).
    * `cells` / `difficulty_misestimates` — comparisons segmented by
      `(difficulty, repo)`, never across cells.
    * `suggestions` — each names a target metric, a baseline, a destination
      (skill / repo `CLAUDE.md` / per-task override) and its evidence tier, so
      a single incident visibly **declines** a fleet-wide change.
    * `scarcity` — the **unit the pass optimises against** (#1463, epic #1011
      Amendment E): which of `window_share_5h` / `cost_usd` binds at this
      installation, how the billing mode was determined (configured vs
      inferred), and the 5h-window calibration every per-run share was divided
      by — including a machine-readable reason when that calibration failed, so
      an uncalibrated window never renders as a cheap one.
    * `finding_residue` (bd-5ja2vb) — the reviewer-finding units
      `Arbiter.Loop.FindingBuckets.bucket_finding/1` matched to no bucket, a
      **first-class corpus-integrity finding** symmetric with
      `misclassification` above: count, rate, distinct tasks and a retained,
      bounded, newest-first sample with `{task_id, run_id}` citations.
    * `notes` — the small-sample caveats, rendered verbatim.
  """

  @enforce_keys [:window, :totals]
  defstruct window: %{},
            totals: %{},
            scarcity: %{},
            segmentation: [],
            misclassification: %{corroborated: 0, reclassified: 0, rate: 0.0, citations: []},
            finding_categories: [],
            difficulty_misestimates: [],
            cells: [],
            suggestions: [],
            finding_residue: Arbiter.Loop.Corpus.empty_finding_residue(),
            notes: []

  @type t :: %__MODULE__{}

  @doc "Render the report as markdown. Pure — no DB, no I/O."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = r) do
    [
      header(r),
      corpus(r),
      scarcity(r),
      segmentation(r),
      misclassification(r),
      finding_categories(r),
      finding_residue(r),
      cells(r),
      difficulty_misestimates(r),
      suggestions(r),
      notes(r)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------

  defp header(%{window: w}) do
    label = Map.get(w, :label, "window")
    span = window_span(w)

    """
    # Loop-analysis report — #{label}
    #{span}
    This pass is **read-only**: it writes nothing but this report and a single
    `usage_events` cost row (zero writes to skills, config, or issues). The
    operator reads it and decides where each lesson lands.
    """
  end

  defp window_span(%{since: since, until: until}) when not is_nil(since) do
    "**Window:** #{iso(since)} → #{iso(until)}\n"
  end

  defp window_span(_), do: ""

  defp corpus(%{totals: t}) do
    """
    ## Corpus

    | metric | count |
    |---|---|
    | dispatches | #{g(t, :dispatches)} |
    | runs | #{g(t, :runs)} |
    | main runs | #{g(t, :main_runs)} |
    | completed | #{g(t, :completed)} |
    | failed | #{g(t, :failed)} |
    | distinct tasks | #{g(t, :tasks)} |
    """
  end

  # #1463: the unit the whole report is denominated in, stated before any
  # number that uses it. Rendered even when uncalibrated — a window whose
  # capacity could not be estimated must say so, because a silent fallback to
  # dollars is exactly the drift Amendment E is about.
  defp scarcity(%{scarcity: %{unit: unit} = s}) do
    {mode, source} = Map.get(s, :billing_mode, {:metered, :default})
    cal = Map.get(s, :calibration, %{})

    """
    ## Unit of scarcity

    | field | value |
    |---|---|
    | primary unit | `#{unit}` |
    | secondary unit | `#{Map.get(s, :secondary_unit)}` |
    | billing mode | #{mode} (#{source}) |
    | 5h calibration | #{calibration_line(cal)} |
    | analyser's own draw | none — deterministic pass, no model call |

    Under **subscription** billing the marginal dollar is not the scarce
    resource; the 5-hour utilization window is — it is the window
    `Arbiter.Quota.Gate` throttles dispatch on. Under **metered** API billing
    dollars bind and lead instead. Whichever is secondary is still reported,
    never dropped. See `docs/loop-scarcity-unit.md`.
    """
  end

  defp scarcity(_), do: ""

  defp calibration_line(%{status: :calibrated} = c) do
    "calibrated — #{round_i(Map.get(c, :capacity_weighted_tokens))} weighted tokens per window " <>
      "(from #{round_i(Map.get(c, :observed_weighted_tokens))} observed at " <>
      "#{pct(Map.get(c, :utilization))} utilization, captured #{iso_or(Map.get(c, :captured_at), "unknown")}). " <>
      "Capacity is a **lower bound** — traffic on this plan from outside Arbiter " <>
      "(an interactive session) raises utilization without writing a `usage_events` " <>
      "row — so every share below is an **upper bound**, and a share over 100% is a " <>
      "known over-estimate, not a measurement."
  end

  # A stale reading is a distinct absence from no reading at all, and the more
  # dangerous one: it is the case that would otherwise calibrate plausibly off a
  # window that has already rolled. Say how old it is.
  defp calibration_line(%{reason: :stale_snapshot} = c) do
    "**uncalibrated** (`stale_snapshot`) — the latest quota reading (captured " <>
      "#{iso_or(Map.get(c, :captured_at), "unknown")}) describes a 5h window that has " <>
      "already reset, so it cannot size the current one; every per-run 5h share this " <>
      "window is `nil`, not zero"
  end

  defp calibration_line(%{reason: reason}),
    do: "**uncalibrated** (`#{reason}`) — every per-run 5h share this window is `nil`, not zero"

  defp calibration_line(_), do: "**uncalibrated** (`no_snapshot`)"

  defp segmentation(%{segmentation: seg}) do
    grouped = Enum.group_by(seg, & &1.class)

    op =
      class_block(
        "Operational (routed to ops — excluded from prompt-shaping analysis)",
        grouped[:operational]
      )

    aq = class_block("Agent-quality (eligible for prompt/skill changes)", grouped[:agent_quality])

    # Unclassified runs are a corpus-integrity signal: they indicate the
    # classifier is drifting from reality. Surface them distinctly with run_ids.
    unknown =
      class_block(
        "**Unclassified (corpus-integrity signal — classifier drift detector)**",
        grouped[:unknown]
      )

    others =
      grouped
      |> Map.drop([:operational, :agent_quality, :unknown])
      |> Enum.map_join("\n", fn {class, rows} -> class_block("#{class}", rows) end)

    """
    ## Failure segmentation (allowlist, not heuristic)

    Split by allowlist. Operational reasons route to ops and are **excluded**
    from prompt-shaping — a naive pass would burn its whole budget on our own
    deploy restarts. Only agent-quality failures can be moved by a prompt or
    skill change.

    #{op}
    #{aq}
    #{unknown}
    #{others}
    """
  end

  defp class_block(_title, nil), do: ""
  defp class_block(_title, []), do: ""

  defp class_block(title, rows) do
    body =
      rows
      |> Enum.map_join("\n", fn row ->
        cites = row |> Map.get(:run_ids, []) |> Enum.take(5) |> Enum.join(", ")
        "| `#{row.subcategory}` | #{row.count} | #{cites} |"
      end)

    """
    ### #{title}

    | subcategory | runs | example run_ids |
    |---|---|---|
    #{body}
    """
  end

  defp misclassification(%{misclassification: m}) do
    cites =
      (Map.get(m, :citations) || [])
      |> Enum.map_join("\n", fn c ->
        "- `#{c.run_id}` — labelled #{inspect(c.failure_reason)}, corrected to `#{c.corrected}`"
      end)

    rate_text = misclassification_rate_text(Map.get(m, :rate), g(m, :corroborated))

    """
    ## Corpus integrity: misclassification rate (`failure_reason` vs transcript)

    `failure_reason` is a hint, not ground truth. Of **#{g(m, :corroborated)}**
    operational-labelled runs corroborated against their transcript,
    **#{g(m, :reclassified)}** disagreed — a misclassification rate of
    **#{rate_text}**. This is a **first-class corpus-integrity
    finding**: a label that hides agent-quality failures behind ops noise is
    worth more than any prompt tweak. Surfaced with citations, not silently
    corrected.

    #{cites}
    """
  end

  defp misclassification_rate_text(nil, 0), do: "n/a (0 corroborated)"
  defp misclassification_rate_text(rate, _), do: pct(rate)

  defp finding_residue_rate_text(nil, 0), do: "n/a (0 finding units)"
  defp finding_residue_rate_text(rate, _), do: pct(rate)

  defp finding_categories(%{finding_categories: []}), do: ""

  defp finding_categories(%{finding_categories: cats}) do
    body =
      cats
      |> Enum.map_join("\n", fn c ->
        tasks = c |> Map.get(:tasks, []) |> Enum.join(", ")
        cites = c |> Map.get(:run_ids, []) |> Enum.join(", ")
        "| #{c.category} | #{c.incidents} | #{tasks} | #{cites} | #{Map.get(c, :example, "")} |"
      end)

    """
    ## Reviewer-finding categories (agent-quality only)

    | category | incidents | tasks | run_ids | example |
    |---|---|---|---|---|
    #{body}
    """
  end

  # bd-5ja2vb: symmetric with `misclassification/1` above — a reviewer finding
  # matching no `FindingBuckets` bucket is a corpus-integrity finding, not a
  # silently dropped unit. Shown unconditionally (like misclassification),
  # not suppressed on zero, so a clean window says "0 of 0" rather than
  # nothing.
  @finding_residue_citation_n 10

  defp finding_residue(%{finding_residue: fr}) do
    total = Map.get(fr, :total_units, 0)
    count = Map.get(fr, :count, 0)
    tasks = Map.get(fr, :distinct_tasks, 0)
    rate_text = finding_residue_rate_text(Map.get(fr, :rate), total)

    cites =
      fr
      |> Map.get(:units, [])
      |> Enum.take(@finding_residue_citation_n)
      |> Enum.map_join("\n", fn u ->
        run = if u.run_id, do: "`#{u.run_id}`", else: "(run_id unresolved)"
        "- `#{u.task_id}` / #{run} — #{u.text}"
      end)

    """
    ## Reviewer-finding residue (corpus-integrity signal — bucket-allowlist drift detector)

    `FindingBuckets.bucket_finding/1` is a four-regex allowlist, not ground
    truth. Of **#{total}** reviewer finding units (`role: review`, non-approve
    rounds) this window, **#{count}** matched none of the buckets — a residue
    rate of **#{rate_text}**, across **#{tasks}** distinct task(s). This is a
    **first-class corpus-integrity finding**, symmetric with the
    misclassification rate above: an allowlist blind spot is worth more than
    any single bucket, and is surfaced with citations rather than silently
    dropped. Residue units are retained (bounded, newest-first, per-unit
    truncated — see `Arbiter.Loop.Corpus.residue_retention_limit/0` and
    `residue_text_limit/0`) so a later merged detector can be backfilled over
    them.

    #{cites}
    """
  end

  defp cells(%{cells: []}), do: ""

  defp cells(%{cells: cells}) do
    body =
      cells
      |> Enum.map_join("\n", fn c ->
        "| #{dlabel(c.difficulty)} | #{c.repo} | #{g(c, :tasks)} | #{pct(Map.get(c, :rework_rate, 0.0))} | #{share(Map.get(c, :mean_window_share_5h))} | $#{money(Map.get(c, :mean_cost_usd))} |"
      end)

    """
    ## Draw & rework by (difficulty, repo) cell

    Compare **within** a cell; metrics move with difficulty mix and repo, so
    cross-cell comparison reads drift as improvement. The **mean 5h share** is
    the binding unit under subscription billing (#1463); mean cost is retained
    as the secondary figure and is the primary one under metered API billing.

    | difficulty | repo | tasks | rework rate | mean 5h share | mean cost |
    |---|---|---|---|---|---|
    #{body}
    """
  end

  defp difficulty_misestimates(%{difficulty_misestimates: []}), do: ""

  defp difficulty_misestimates(%{difficulty_misestimates: mis}) do
    body =
      mis
      |> Enum.map_join("\n", fn m ->
        {d, repo} = Map.get(m, :cell, {Map.get(m, :dispatched_difficulty), "?"})
        rec = Map.get(m, :recommendation, %{})

        """
        ### #{m.task_id} — cell (#{d}, #{repo})

        - **Dispatched difficulty:** D#{Map.get(m, :dispatched_difficulty)}
        - **Rounds:** #{Map.get(m, :rounds)}
        - **5h-window share:** #{share(Map.get(m, :window_share_5h))}
        - **Cost:** $#{money(Map.get(m, :cost_usd))}
        - **Note:** #{Map.get(m, :note, "")}
        - **Recommendation:** #{destination(Map.get(rec, :destination))} — #{Map.get(rec, :action, "")}
        - **Target metric:** #{Map.get(rec, :target_metric)} (baseline: #{Map.get(rec, :baseline)})
        """
      end)

    """
    ## Difficulty misestimates (segmented by (difficulty, repo) cell)

    #{body}
    """
  end

  defp suggestions(%{suggestions: []}), do: ""

  defp suggestions(%{suggestions: suggestions}) do
    body =
      suggestions
      |> Enum.map_join("\n", fn s ->
        ev = Map.get(s, :evidence, %{})
        incidents = Map.get(ev, :incidents, 0)
        tasks = Map.get(ev, :tasks, 0)

        """
        ### #{s.title}

        - **Target metric:** #{Map.get(s, :target_metric)}
        - **Baseline:** #{Map.get(s, :baseline)}
        - **Destination:** #{destination(Map.get(s, :destination))}
        - **Evidence:** #{incidents} incidents across #{tasks} tasks
        - **Verdict:** #{verdict(Map.get(s, :verdict))} — #{Map.get(s, :rationale, "")}
        """
      end)

    """
    ## Suggestions

    Every suggestion names the metric it should move, that metric's current
    baseline, and a destination — a **skill** (general working practice), the
    repo's **`CLAUDE.md`** (repo-specific convention), or a **per-task override**
    (single incident, blast-radius-1). A finding below the ≥3-incident / ≥2-task
    bar visibly declines a fleet-wide change.

    #{body}
    """
  end

  defp notes(%{notes: []}), do: ""

  defp notes(%{notes: notes}) do
    body = notes |> Enum.map_join("\n", &"- #{&1}")

    """
    ## Caveats

    #{body}
    """
  end

  # --- formatting ------------------------------------------------------------

  defp destination(:skill), do: "skill"
  defp destination(:claude_md), do: "repo `CLAUDE.md`"
  defp destination(:per_task), do: "per-task override"
  defp destination(:per_task_override), do: "per-task override"
  defp destination(nil), do: "unspecified"
  defp destination(other), do: to_string(other)

  defp verdict(:fleet_wide), do: "fleet-wide"
  defp verdict(:per_task), do: "per-task override"
  defp verdict(:per_task_override), do: "per-task override"
  defp verdict(nil), do: "—"
  defp verdict(other), do: to_string(other)

  defp g(map, key), do: Map.get(map, key, 0)

  defp dlabel(nil), do: "D? (unset)"
  defp dlabel(d), do: "D#{d}"

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(other), do: to_string(other)

  defp pct(rate) when is_number(rate), do: "#{Float.round(rate * 100, 1)}%"
  defp pct(_), do: "n/a"

  defp share(s) when is_number(s), do: "#{Float.round(s * 100, 1)}%"
  defp share(_), do: "n/a"

  defp round_i(n) when is_number(n), do: n |> round() |> Integer.to_string()
  defp round_i(_), do: "?"

  defp iso_or(%DateTime{} = dt, _fallback), do: iso(dt)
  defp iso_or(_other, fallback), do: fallback

  defp money(nil), do: "0.00"
  defp money(n) when is_integer(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp money(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp money(n), do: to_string(n)
end
