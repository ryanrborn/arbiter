defmodule Arbiter.Usage.Budget do
  @moduledoc """
  What a task has spent so far, read against what tasks like it usually cost
  (bd-8j9i9p; design bd-9jj5lf §3 and §7).

  `Arbiter.Usage.Estimate` answers "what should this cost?". This module
  answers the other half — "what has it cost, and is that a lot?" — and
  defines the three states every surface renders off:

  | state | condition | reads as |
  |---|---|---|
  | `:normal` | spend ≤ p75 | nothing; no chip |
  | `:running_high` | p75 < spend ≤ p90 | amber "running high" |
  | `:over_budget` | spend > p90 | red "over budget" |
  | `:no_estimate` | no estimate at all | "no estimate yet" |

  Both boundaries are exclusive on purpose: a task that lands *exactly* on its
  group's p75 is a task that cost what a quarter of its peers cost, which is
  not a finding. Only passing the mark is.

  ## Worker spend only (design §7)

  Every figure here sums `source: :task` rows — worker sessions and their
  review / fix-pass rounds. Coordinator-session spend is metered per session
  and attributable to no task, so it is out of both this number and the
  estimate it is compared against. Surfaces must say "worker spend", not
  "spent", so nobody reads it as the task's all-in cost to the org.

  ## The same hygiene as the estimator

  * **Synthetic ids fold to the base task** — a task's spend is its work
    session plus every `#review` / `#impl2` / `:fixpass` round.
    `base_task_id` carries that link for rows written after migration
    `20260820000000`; older rows are caught by a `<id>#%` prefix match and
    folded with `Arbiter.Usage.Estimate.fold_task_id/1`, which is also what
    rejects a prefix match that folds to somebody else.
  * **Unpriced rows are excluded, not zeroed** — a `cost_usd: nil` row means
    the CLI reported no price, so the total is a floor, not a fiction.

  Unlike the estimator there is no window and no closed-task filter: this is
  one task's own running total, and all of it counts.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event

  require Ash.Expr
  require Ash.Query
  require Logger

  # Matches the estimator's chunking: SQLite's expression-tree limit is what
  # an unbounded `in` list runs into first (~1000 ids).
  @id_chunk 200

  # `Estimate.t().basis` sentinel for `assess_epic/2`'s summed range, so a
  # surface can tell an aggregate apart from a peer-group basis
  # ("difficulty+type", "difficulty", "global", "unrated_as_d2") without a
  # second field.
  @epic_estimate_basis "epic_children"

  @type state :: :normal | :running_high | :over_budget | :no_estimate

  @type assessment :: %{
          spend: float(),
          estimate: Estimate.t() | nil,
          state: state(),
          over_budget?: boolean()
        }

  @doc """
  Worker spend so far for one task, in dollars. `0.0` when it has spent
  nothing — which is a fact about the task, not a missing answer.
  """
  @spec spend_so_far(Issue.t() | String.t(), keyword()) :: float()
  def spend_so_far(issue_or_id, opts \\ [])
  def spend_so_far(%Issue{id: id}, opts), do: spend_so_far(id, opts)

  def spend_so_far(task_id, opts) when is_binary(task_id) do
    [task_id]
    |> spend_by_task(opts)
    |> Map.get(task_id, 0.0)
  end

  @doc """
  Worker spend so far for many tasks: `%{task_id => dollars}`.

  A task that has spent nothing has **no key** rather than a `0.0` one —
  callers that need the distinction ("no ledger rows at all" vs. "rows that
  summed to nothing") get it, and `Map.get(spends, id, 0.0)` collapses it for
  callers that don't.
  """
  @spec spend_by_task([String.t()], keyword()) :: %{String.t() => float()}
  def spend_by_task(task_ids, opts \\ []) when is_list(task_ids) do
    ids =
      task_ids
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    wanted = MapSet.new(ids)

    ids
    |> Enum.chunk_every(Keyword.get(opts, :id_chunk, @id_chunk))
    |> Enum.flat_map(&read_chunk/1)
    |> Enum.filter(&is_number(&1.cost_usd))
    |> Enum.group_by(&fold_event_id/1)
    |> Enum.filter(fn {task_id, _events} -> MapSet.member?(wanted, task_id) end)
    |> Map.new(fn {task_id, events} ->
      {task_id, money(Enum.reduce(events, 0.0, &(&2 + &1.cost_usd)))}
    end)
  end

  # One query per chunk. `base_task_id` is the indexed, authoritative link;
  # `task_id` catches the base row itself; the `<id>#%` prefix catches the
  # pre-migration synthetic rows that have neither. `fold_event_id/1` above
  # then decides what each row really belongs to, so a prefix match that folds
  # elsewhere is dropped rather than trusted.
  defp read_chunk([]), do: []

  defp read_chunk(ids) do
    task_source = :task

    Event
    |> Ash.Query.filter(source == ^task_source and not is_nil(task_id))
    |> Ash.Query.filter(^ids_filter(ids))
    # Never `raw`: it holds the agent CLI's whole result payload and decoding
    # one per row is most of the cost of this read.
    |> Ash.Query.select([:task_id, :base_task_id, :cost_usd])
    |> Ash.read!()
  end

  defp ids_filter(ids) do
    Enum.reduce(ids, false, fn id, acc ->
      prefix = id <> "#%"

      Ash.Expr.expr(^acc or base_task_id == ^id or task_id == ^id or like(task_id, ^prefix))
    end)
  end

  defp fold_event_id(%Event{base_task_id: base}) when is_binary(base) and base != "",
    do: Estimate.fold_task_id(base)

  defp fold_event_id(%Event{task_id: task_id}), do: Estimate.fold_task_id(task_id)

  @doc """
  Spend so far, the estimate it is read against, and the resulting state.

  Options are `Arbiter.Usage.Estimate.for_issue/2`'s (`:sample`, `:now`,
  `:window_days`, `:min_n`), plus `:spend` to supply an already-computed
  total — which is how a caller assessing many issues avoids a ledger read
  per issue.
  """
  @spec assess(Issue.t(), keyword()) :: assessment()
  def assess(%Issue{} = issue, opts \\ []) do
    spend = Keyword.get_lazy(opts, :spend, fn -> spend_so_far(issue.id, opts) end)

    estimate =
      case Estimate.for_issue(issue, opts) do
        :insufficient_data -> nil
        est -> est
      end

    state = state(spend, estimate)

    %{spend: spend, estimate: estimate, state: state, over_budget?: state == :over_budget}
  end

  @doc "The `Estimate.t().basis` sentinel `assess_epic/2` marks its summed range with."
  @spec epic_estimate_basis() :: String.t()
  def epic_estimate_basis, do: @epic_estimate_basis

  @doc """
  `assess/2`'s epic counterpart: nothing dispatches an epic itself, so its own
  ledger is empty and `Estimate.for_issue/2` would only ever hand it a
  peer-group range built out of costs it has nothing to do with. This instead
  rolls both halves up over the epic's direct children (design bd-9jj5lf, per
  bd-byp30z):

    * **spend** — the epic's own worker spend (almost always none) plus every
      direct child's, across *all* buckets — backlog, ready, running,
      waiting, closed — not just closed ones. One
      `Arbiter.Tasks.EpicRollup.children_with_status/1` call for membership,
      one `spend_by_task/2` read over `[epic.id | child_ids]`.
    * **estimate** — each non-epic child's own `Estimate.for_issue/2` range,
      summed percentile-for-percentile (p25+p25, median+median, …) over one
      shared `Estimate.sample/1`. Sub-epic children are skipped (their peer
      group is the same fiction this function exists to avoid) and so are
      children the estimator has no history for (`:insufficient_data`
      contributes nothing, same as a task-level `estimate: nil`). `nil` when
      no child contributes anything. `basis` is `epic_estimate_basis/0`
      rather than a peer-group basis, and `n` counts contributing children,
      not sample rows.

  One ledger read and one estimator sample cover an N-child epic, same as
  `Estimate.epic_cost_rollup/2`.

  Unlike `assess/2`, this does **not** accept a `:spend` option. `assess/2`'s
  `:spend` lets a caller supply an already-computed *per-issue* total to skip
  a ledger read; here the total is a rollup over the epic plus every direct
  child by definition, so there is no single precomputed number a caller
  could sensibly hand in instead — passing `:spend` is silently ignored
  rather than honoured.

  **The summed range overstates the tails.** The p90 of a sum sits below the
  sum of the children's individual p90s unless every child runs hot at once,
  so `state/2` fires `:running_high` / `:over_budget` later than a "true"
  epic-level p90 would. That is the safer direction to be wrong in — it costs
  a late flag, not a false one — but it does mean the aggregate range reads
  wider than an epic's real spread.

  **This is not `Estimate.epic_cost_rollup/2`'s number.** The COST ROLLUP
  panel's `spent` is closed children only, so its "spent · to go" sentence
  holds together; this `spend` is everything so far, in-flight children
  included, because a header answering "what has this epic cost" should not
  hide money still being spent. The two are expected to disagree on the same
  page.

  `state/2` unchanged: `assess/2`'s per-issue semantics stay on `assess/2`
  and `Arbiter.Usage.BudgetPatrol`, which already passes `:spend` explicitly.
  """
  @spec assess_epic(Issue.t(), keyword()) :: assessment()
  def assess_epic(%Issue{issue_type: :epic} = epic, opts \\ []) do
    children = Arbiter.Tasks.EpicRollup.children_with_status(epic)
    child_issues = Enum.map(children, & &1.issue)
    ids = [epic.id | Enum.map(child_issues, & &1.id)]

    spend =
      ids
      |> spend_by_task(opts)
      |> Map.values()
      |> Enum.reduce(0.0, &+/2)
      |> money()

    estimate = epic_estimate(child_issues, opts)
    state = state(spend, estimate)

    %{spend: spend, estimate: estimate, state: state, over_budget?: state == :over_budget}
  end

  defp epic_estimate(children, opts) do
    children
    |> Enum.reject(&(&1.issue_type == :epic))
    |> case do
      [] ->
        nil

      candidates ->
        opts = Keyword.put_new_lazy(opts, :sample, fn -> Estimate.sample(opts) end)

        candidates
        |> Enum.map(&Estimate.for_issue(&1, opts))
        |> Enum.reject(&(&1 == :insufficient_data))
        |> sum_estimates()
    end
  end

  defp sum_estimates([]), do: nil

  defp sum_estimates(estimates) do
    zero = %{p25: 0.0, median: 0.0, p75: 0.0, p90: 0.0}

    totals =
      Enum.reduce(estimates, zero, fn est, acc ->
        %{
          p25: acc.p25 + est.p25,
          median: acc.median + est.median,
          p75: acc.p75 + est.p75,
          p90: acc.p90 + est.p90
        }
      end)

    %{
      p25: money(totals.p25),
      median: money(totals.median),
      p75: money(totals.p75),
      p90: money(totals.p90),
      n: length(estimates),
      basis: @epic_estimate_basis,
      fallback_level: 0
    }
  end

  @doc """
  The threshold state for a spend / estimate pair. See the moduledoc table.
  """
  @spec state(float(), Estimate.t() | nil | :insufficient_data) :: state()
  def state(_spend, nil), do: :no_estimate
  def state(_spend, :insufficient_data), do: :no_estimate

  def state(spend, %{p75: p75, p90: p90}) when is_number(spend) do
    cond do
      spend > p90 -> :over_budget
      spend > p75 -> :running_high
      true -> :normal
    end
  end

  def state(_spend, _estimate), do: :no_estimate

  @doc """
  The ids among `issues` that are **open and past their p90** — the board's
  attention set (design §3).

  A closed task that ran over is done: there is nothing to act on, and it is
  calibration-report material instead, so it is never in this list however far
  over it ran. One ledger read and one estimator sample cover the whole input.

  Best-effort: a failed ledger read costs the board its cost flags, not its
  columns.
  """
  @spec over_budget_ids([Issue.t() | map()], keyword()) :: [String.t()]
  def over_budget_ids(issues, opts \\ []) when is_list(issues) do
    open = Enum.filter(issues, &open?/1)

    case open do
      [] ->
        []

      open ->
        sample = Keyword.get_lazy(opts, :sample, fn -> Estimate.sample(opts) end)
        spends = spend_by_task(Enum.map(open, & &1.id), opts)
        opts = Keyword.put(opts, :sample, sample)

        open
        |> Enum.filter(fn issue ->
          spend = Map.get(spends, issue.id, 0.0)

          spend > 0.0 and
            state(spend, Estimate.for_issue(to_issue(issue), opts)) == :over_budget
        end)
        |> Enum.map(& &1.id)
    end
  rescue
    error ->
      Logger.warning("Usage.Budget.over_budget_ids failed: #{Exception.message(error)}")
      []
  end

  # The board hands `derive/1` plain maps in its pure tests and `%Issue{}`
  # structs in production; the estimator only needs the two grouping keys.
  defp to_issue(%Issue{} = issue), do: issue

  defp to_issue(card) when is_map(card),
    do: %Issue{
      id: Map.get(card, :id),
      difficulty: Map.get(card, :difficulty),
      issue_type: Map.get(card, :issue_type)
    }

  defp open?(issue), do: Map.get(issue, :status) != :closed and is_binary(Map.get(issue, :id))

  defp money(value), do: Float.round(value / 1, 2)
end
