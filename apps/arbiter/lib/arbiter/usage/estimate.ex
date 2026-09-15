defmodule Arbiter.Usage.Estimate do
  @moduledoc """
  Empirical cost estimates for a task, derived from the usage ledger
  (bd-3j4ch4; design bd-9jj5lf §1, §2, §6, §8).

  There is no model here beyond "what did tasks like this one actually cost?".
  `for_issue/2` sums the ledger per closed task over a rolling window, groups
  the totals by the coarsest key that still has enough history, and reports
  the group's percentile spread. Spread is the point: p90 runs ~2.5× the
  median, so a single number would be a lie and the estimate is always a
  range.

  ## The fallback ladder

  Finest group first, each rung needing `n >= 10` closed tasks:

  | rung | key | `basis` | `fallback_level` |
  |---|---|---|---|
  | 1 | `(difficulty, issue_type)` | `"difficulty+type"` | `0` |
  | 2 | `(difficulty)` | `"difficulty"` | `1` |
  | 3 | every closed task | `"global"` | `2` |

  Below that, `:insufficient_data` — never an invented number. `repo` is
  deliberately *not* a key: it is null on ~64% of rows, so keying on it would
  fragment every group below the threshold (design §1a). Model tier likewise:
  D0–D3 all route to the same tier today, so splitting on it would only thin
  out D4.

  An unrated task (`difficulty: nil`) borrows D2's numbers — the tier routing
  already treats it as — and says so with `basis: "unrated_as_d2"`, so the
  caller can caveat it rather than presenting a fake "unrated" distribution.

  ## Data hygiene (design §2)

  * **Synthetic ids fold to the base task.** A task's real cost is its work
    session *plus* every review and revise round. `base_task_id` carries that
    link for rows written after migration `20260820000000` (bd-5fhyry); older
    rows only have the suffix on `task_id`, so `fold_task_id/1` strips it.
    Without this, rework reads as a crowd of separate cheap "tasks" and drags
    every percentile down.
  * **Unpriced rows are excluded, not zeroed.** A row with `cost_usd: nil`
    means the CLI reported no cost, not that the session was free. A task
    whose rows are *all* unpriced contributes no data point at all.
  * **Worker spend only** (`source: :task`). Coordinator/terminal sessions are
    metered per session and attributable to no task (design §7).
  * **Closed tasks only** — an open task's total is still moving.
  * **Rolling 60-day window, recency weighted** with a 30-day half-life.
    History includes churn that is actively being fixed; a hard window edge
    would let a bad week drop off a cliff on day 61, so old spend fades
    instead.

  ## Percentile definition

  Nearest-rank over cumulative weight: `p` is the smallest observed cost whose
  running weight share reaches `p`. With equal weights this is the ordinary
  nearest-rank percentile (p50 of ten values is the 5th smallest). No
  interpolation — every reported figure is a cost some real task actually
  incurred, which is the honest thing to show next to "spent so far".

  ## Cost

  Compute-on-read (design §8): one indexed range scan over a 60-day window
  plus one `id in [...]` issue fetch, both in the hundreds of rows. Callers
  estimating many issues at once should build the sample once and pass it as
  `:sample`.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage.Event

  require Ash.Query

  @window_days 60
  @half_life_days 30
  @min_group_n 10
  @unrated_difficulty 2

  # Everything from the first `#` is a ReviewGate synthetic-suffix chain
  # (`#review`, `#impl2`, `#r3`, `#v2`, `#t2`, or several chained) — the same
  # split `Arbiter.Worker.ReviewGate.base_task_id/1` does.
  # The merge queue's subordinate passes suffix with a colon instead
  # (`:fixpass`, `:conflict`), and older fix-pass rows wrote a literal
  # `fix_pass` marker.
  @fix_pass_suffix ~r/[:#_-]fix_?pass$/

  @type t :: %{
          p25: float(),
          median: float(),
          p75: float(),
          p90: float(),
          n: non_neg_integer(),
          basis: String.t(),
          fallback_level: 0..2
        }

  @type task_cost :: %{
          task_id: String.t(),
          title: String.t() | nil,
          difficulty: integer() | nil,
          issue_type: atom() | nil,
          cost_usd: float(),
          occurred_at: DateTime.t(),
          weight: float(),
          priced_rows: non_neg_integer(),
          unpriced_rows: non_neg_integer(),
          work_sessions: non_neg_integer(),
          re_dispatched: boolean()
        }

  @doc "The rolling window, in days."
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc "Closed tasks a group needs before its own percentiles are trusted."
  @spec min_group_n() :: pos_integer()
  def min_group_n, do: @min_group_n

  # ---- estimate ----------------------------------------------------------

  @doc """
  Percentile estimate for one issue, or `:insufficient_data`.

  Accepts a loaded `%Arbiter.Tasks.Issue{}` or a task id. Returns
  `%{p25:, median:, p75:, p90:, n:, basis:, fallback_level:}`.

  ## Options

    * `:sample` — a pre-built sample from `sample/1`, to estimate many issues
      without re-querying per issue.
    * `:now` — clock override (tests / back-tests).
    * `:window_days` — override the #{@window_days}-day window.
    * `:min_n` — override the `n >= #{@min_group_n}` group threshold.
  """
  @spec for_issue(Issue.t() | String.t(), keyword()) :: t() | :insufficient_data
  def for_issue(issue_or_id, opts \\ [])

  def for_issue(%Issue{} = issue, opts) do
    opts
    |> resolve_sample()
    |> estimate_from(issue.difficulty, issue.issue_type, opts)
  end

  def for_issue(task_id, opts) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = issue} -> for_issue(issue, opts)
      # An id we can't resolve has no difficulty and no type to group on —
      # there is nothing to estimate from, which is the same answer as a
      # ledger too thin to use.
      _ -> :insufficient_data
    end
  end

  @doc """
  `for_issue/2` in the wire shape the MCP `task_show` response and
  `arb issue show` render: `%{range: [p25, p75], median:, p90:, n:, basis:,
  fallback_level:}`, or `nil` when there is not enough history.
  """
  @spec payload(Issue.t() | String.t(), keyword()) :: map() | nil
  def payload(issue_or_id, opts \\ []) do
    case for_issue(issue_or_id, opts) do
      :insufficient_data ->
        nil

      est ->
        %{
          range: [est.p25, est.p75],
          median: est.median,
          p90: est.p90,
          n: est.n,
          basis: est.basis,
          fallback_level: est.fallback_level
        }
    end
  end

  defp resolve_sample(opts) do
    case Keyword.fetch(opts, :sample) do
      {:ok, sample} when is_list(sample) -> sample
      _ -> sample(opts)
    end
  end

  defp estimate_from(sample, difficulty, issue_type, opts) do
    min_n = Keyword.get(opts, :min_n, @min_group_n)
    unrated? = is_nil(difficulty)
    difficulty = difficulty || @unrated_difficulty

    rungs = [
      {0, "difficulty+type",
       &(&1.difficulty == difficulty and &1.issue_type == issue_type)},
      {1, "difficulty", &(&1.difficulty == difficulty)},
      {2, "global", fn _row -> true end}
    ]

    Enum.find_value(rungs, :insufficient_data, fn {level, basis, pred} ->
      rows = Enum.filter(sample, pred)

      if length(rows) >= min_n do
        rows
        |> percentiles()
        |> Map.merge(%{
          n: length(rows),
          basis: if(unrated?, do: "unrated_as_d2", else: basis),
          fallback_level: level
        })
      end
    end)
  end

  # ---- calibration (design §6) -------------------------------------------

  @doc """
  Mis-rating report: closed tasks whose actual cost lands outside their own
  tier's p25–p75 but inside an adjacent tier's.

  A cost above its tier's p75 that fits the tier above reads as **possibly
  under-rated**; below its tier's p25 and fitting the tier below, **possibly
  over-rated**. Only tiers with `n >= #{@min_group_n}` are used, in either
  direction — comparing against a three-task tier's IQR would flag noise.

  Re-dispatched tasks (more than one `:work` session — re-slung after a
  failure) are listed but **excluded from the per-tier rates**: re-slinging
  inflates cost without saying anything about how hard the task was, and
  counting it would read as "D-ratings run low" when it means "the worker
  died once".

  Returns `%{window_days:, tiers: [...], flagged: [...],
  re_dispatched_flagged:}`. Takes the same options as `for_issue/2`.
  """
  @spec calibration(keyword()) :: map()
  def calibration(opts \\ []) do
    min_n = Keyword.get(opts, :min_n, @min_group_n)

    rated =
      opts
      |> resolve_sample()
      |> Enum.reject(&is_nil(&1.difficulty))

    by_tier = Enum.group_by(rated, & &1.difficulty)

    tier_iqr =
      Map.new(by_tier, fn {d, rows} ->
        {d, if(length(rows) >= min_n, do: percentiles(rows))}
      end)

    flagged =
      rated
      |> Enum.map(&classify(&1, tier_iqr))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{&1.difficulty, -&1.actual_cost_usd})

    tiers =
      by_tier
      |> Enum.map(fn {d, rows} -> tier_row(d, rows, tier_iqr[d], flagged) end)
      |> Enum.sort_by(& &1.difficulty)

    %{
      window_days: Keyword.get(opts, :window_days, @window_days),
      tiers: tiers,
      flagged: flagged,
      re_dispatched_flagged: Enum.count(flagged, & &1.re_dispatched)
    }
  end

  defp classify(row, tier_iqr) do
    own = tier_iqr[row.difficulty]

    cond do
      is_nil(own) ->
        nil

      row.cost_usd > own.p75 and within?(row.cost_usd, tier_iqr[row.difficulty + 1]) ->
        flag(row, :under_rated, row.difficulty + 1)

      row.cost_usd < own.p25 and within?(row.cost_usd, tier_iqr[row.difficulty - 1]) ->
        flag(row, :over_rated, row.difficulty - 1)

      true ->
        nil
    end
  end

  defp within?(_cost, nil), do: false
  defp within?(cost, %{p25: lo, p75: hi}), do: cost >= lo and cost <= hi

  defp flag(row, direction, suggested) do
    %{
      task_id: row.task_id,
      title: row.title,
      difficulty: row.difficulty,
      issue_type: row.issue_type,
      actual_cost_usd: row.cost_usd,
      direction: direction,
      suggested_difficulty: suggested,
      re_dispatched: row.re_dispatched
    }
  end

  defp tier_row(difficulty, rows, iqr, flagged) do
    re_dispatched = Enum.count(rows, & &1.re_dispatched)
    scored = length(rows) - re_dispatched

    tier_flags =
      Enum.filter(flagged, &(&1.difficulty == difficulty and not &1.re_dispatched))

    under = Enum.count(tier_flags, &(&1.direction == :under_rated))
    over = Enum.count(tier_flags, &(&1.direction == :over_rated))

    %{
      difficulty: difficulty,
      n: length(rows),
      re_dispatched: re_dispatched,
      n_scored: scored,
      p25: iqr && iqr.p25,
      median: iqr && iqr.median,
      p75: iqr && iqr.p75,
      p90: iqr && iqr.p90,
      under_rated: under,
      over_rated: over,
      under_rate: rate(under, scored),
      over_rate: rate(over, scored)
    }
  end

  defp rate(_count, 0), do: 0.0
  defp rate(count, scored), do: count / scored

  # ---- sample ------------------------------------------------------------

  @doc """
  The estimator's population: one row per closed task with at least one priced
  worker-spend event inside the window.

  See the moduledoc for the hygiene rules applied here. Exposed because the
  calibration report and any multi-issue caller want to build it once, and
  because "what is actually in the sample" is the first question when an
  estimate looks wrong.
  """
  @spec sample(keyword()) :: [task_cost()]
  def sample(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    window = Keyword.get(opts, :window_days, @window_days)
    since = DateTime.add(now, -window, :day)
    task_source = :task

    query =
      Event
      |> Ash.Query.filter(source == ^task_source and occurred_at >= ^since)
      |> Ash.Query.filter(not is_nil(task_id))

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) and ws != "" -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    folded =
      query
      |> Ash.read!()
      |> Enum.group_by(&fold_event_id/1)
      |> Enum.map(fn {task_id, events} -> fold_task(task_id, events, now) end)
      |> Enum.reject(&is_nil/1)

    attach_issues(folded)
  end

  # `base_task_id` is authoritative where the migration filled it in; older
  # rows fall back to the suffix regex. Both go through fold_task_id/1 — a
  # backfilled base_task_id can itself still carry a suffix.
  defp fold_event_id(%Event{base_task_id: base}) when is_binary(base) and base != "",
    do: fold_task_id(base)

  defp fold_event_id(%Event{task_id: task_id}), do: fold_task_id(task_id)

  @doc """
  Strip a synthetic-id suffix back to the base task id.

  Handles the ReviewGate chain (`#review`, `#impl2`, `#r3`, `#v2`, `#t2`, and
  chains of them), the merge queue's `:fixpass` / `:conflict` passes, and the
  literal `fix_pass` marker on older rows. A plain id passes through.
  """
  @spec fold_task_id(String.t()) :: String.t()
  def fold_task_id(task_id) when is_binary(task_id) do
    task_id
    |> String.split("#", parts: 2)
    |> hd()
    |> String.replace(@fix_pass_suffix, "")
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp fold_task(task_id, events, now) do
    {priced, unpriced} = Enum.split_with(events, &is_number(&1.cost_usd))

    # A task whose every row is unpriced is not a cheap task — it is a task we
    # have no price for. Contributing it as a data point would invent a
    # low-cost observation out of missing data.
    if priced == [] do
      nil
    else
      latest = priced |> Enum.map(& &1.occurred_at) |> Enum.max(DateTime)

      work_sessions =
        Enum.count(events, &(&1.step == :work and &1.role in [nil, "", "base"]))

      %{
        task_id: task_id,
        title: nil,
        difficulty: nil,
        issue_type: nil,
        cost_usd: Enum.reduce(priced, 0.0, &(&2 + &1.cost_usd)),
        occurred_at: latest,
        weight: recency_weight(latest, now),
        priced_rows: length(priced),
        unpriced_rows: length(unpriced),
        work_sessions: work_sessions,
        re_dispatched: work_sessions > 1
      }
    end
  end

  # Exponential decay with a #{@half_life_days}-day half-life: today's spend
  # counts double what a month-old task's does, and the 60-day edge fades to
  # a quarter rather than dropping off a cliff.
  defp recency_weight(%DateTime{} = occurred_at, %DateTime{} = now) do
    age_days = max(DateTime.diff(now, occurred_at, :second) / 86_400, 0.0)
    :math.pow(0.5, age_days / @half_life_days)
  end

  # Join to the issues table: the sample is closed tasks only, and difficulty /
  # issue_type are the grouping keys.
  defp attach_issues([]), do: []

  defp attach_issues(rows) do
    ids = Enum.map(rows, & &1.task_id)
    closed = :closed

    issues =
      Issue
      |> Ash.Query.filter(id in ^ids and status == ^closed)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1})

    rows
    |> Enum.filter(&Map.has_key?(issues, &1.task_id))
    |> Enum.map(fn row ->
      issue = issues[row.task_id]

      %{
        row
        | title: issue.title,
          difficulty: issue.difficulty,
          issue_type: issue.issue_type
      }
    end)
  end

  # ---- percentiles -------------------------------------------------------

  @doc """
  Weighted p25 / median / p75 / p90 over a list of sample rows.

  Nearest-rank on cumulative weight (see the moduledoc), rounded to cents.
  """
  @spec percentiles([task_cost()]) :: %{p25: float(), median: float(), p75: float(), p90: float()}
  def percentiles(rows) do
    pairs =
      rows
      |> Enum.map(&{&1.cost_usd, &1.weight})
      |> Enum.sort_by(&elem(&1, 0))

    total = Enum.reduce(pairs, 0.0, fn {_v, w}, acc -> acc + w end)

    %{
      p25: percentile(pairs, total, 0.25),
      median: percentile(pairs, total, 0.5),
      p75: percentile(pairs, total, 0.75),
      p90: percentile(pairs, total, 0.90)
    }
  end

  defp percentile([], _total, _p), do: nil

  defp percentile(pairs, total, p) do
    target = p * total

    result =
      Enum.reduce_while(pairs, 0.0, fn {value, weight}, acc ->
        acc = acc + weight

        # 1.0e-9 absorbs the float drift of summing weights, so an exactly-on-
        # the-boundary rank (p50 of ten equal weights) doesn't slip a rank.
        if acc + 1.0e-9 >= target, do: {:halt, {:found, value}}, else: {:cont, acc}
      end)

    case result do
      {:found, value} -> money(value)
      _ -> pairs |> List.last() |> elem(0) |> money()
    end
  end

  defp money(value), do: Float.round(value / 1, 2)
end
