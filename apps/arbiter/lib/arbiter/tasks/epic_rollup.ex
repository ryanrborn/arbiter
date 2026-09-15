defmodule Arbiter.Tasks.EpicRollup do
  @moduledoc """
  Per-status child aggregation for an epic, plus the three derived stuck
  signals the `/epics` page chips off it (bd-2wmxt5, §2 of the bd-2s901b
  design).

  Neither `child_open` nor a per-status count exists on `Issue` — the resource
  only carries the `child_total` / `child_closed` calculations — so this module
  derives the breakdown from the children themselves.

  ## Buckets

  The five buckets mirror the board's columns, but are derived from the
  *issue*, not from a worker row: an epic's page is about where its children
  stand in the ledger, and a child can be `:in_progress` with its worker
  already gone.

      :closed    status == :closed
      :waiting   status == :awaiting_verification
      :running   status == :in_progress
      :ready     status == :open and refined
      :backlog   status == :open and not refined

  Absent `refined` reads as unrefined, same as `Arbiter.Board.Snapshot`.

  ## Stuck signals

  Computed, not stored — the same derivation style as the board's
  `needs_you?/2`:

    * `:blocked_children` — a non-closed child with an open gating blocker
      (`:depends_on` out / `:blocks` in, blocker not closed). Mirrors the
      board's `blockers_from/2` gating rule.
    * `:awaiting_verification` — a child parked in `:awaiting_verification`.
    * `:idle_with_ready_work` — zero running children while at least one child
      is Ready: queueable work nobody has picked up.

  ## Queries

  Children come from `Arbiter.Tasks.Dependencies.for_issue/1` — the same facade
  the detail page reads — one call per epic, rather than a second hand-rolled
  `:parent_of` query. The gating edges and the blockers' statuses are then read
  in two bulk queries across *all* the epics' children, so the blocked-child
  signal costs a constant two reads regardless of how many epics are listed.
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.Issue

  @empty_counts %{backlog: 0, ready: 0, running: 0, waiting: 0, closed: 0}

  # Chip order on the page: why it can't move, then what it's waiting on, then
  # that nothing is moving at all.
  @signal_order [:blocked_children, :awaiting_verification, :idle_with_ready_work]

  @type t :: %{
          epic_id: String.t(),
          counts: %{backlog: non_neg_integer(), ready: non_neg_integer(), running: non_neg_integer(), waiting: non_neg_integer(), closed: non_neg_integer()},
          total: non_neg_integer(),
          closed: non_neg_integer(),
          percent_complete: non_neg_integer(),
          blocked_children: non_neg_integer(),
          awaiting_verification: non_neg_integer(),
          idle_with_ready_work: boolean(),
          stuck: [atom()],
          last_child_activity_at: DateTime.t() | nil
        }

  @doc """
  Roll up every epic in `epics`, keyed by epic id.

  Accepts `%Issue{}` structs or bare ids. Every epic passed in gets a rollup,
  including childless ones (all-zero counts, no stuck signals).
  """
  @spec for_epics([Issue.t() | String.t()]) :: %{String.t() => t()}
  def for_epics(epics) do
    epic_ids = Enum.map(epics, &epic_id/1)

    children_by_epic = Map.new(epic_ids, &{&1, children_of(&1)})

    all_children =
      children_by_epic |> Map.values() |> List.flatten() |> Map.new(&{&1.id, &1}) |> Map.values()

    blocked = blocked_ids(all_children)

    Map.new(children_by_epic, fn {epic_id, children} ->
      {epic_id, rollup(epic_id, children, blocked)}
    end)
  end

  @doc """
  The rollup for a single epic. Convenience over `for_epics/1`.
  """
  @spec for_epic(Issue.t() | String.t()) :: t()
  def for_epic(epic) do
    id = epic_id(epic)
    Map.fetch!(for_epics([epic]), id)
  end

  defp epic_id(%{id: id}), do: id
  defp epic_id(id) when is_binary(id), do: id

  defp children_of(epic_id) do
    epic_id
    |> Dependencies.for_issue()
    |> Map.get(:children, [])
    |> Enum.map(& &1.issue)
    |> Enum.reject(&is_nil/1)
  end

  defp rollup(epic_id, children, blocked) do
    counts =
      Enum.reduce(children, @empty_counts, fn child, acc ->
        Map.update!(acc, bucket(child), &(&1 + 1))
      end)

    total = length(children)
    blocked_children = Enum.count(children, &MapSet.member?(blocked, &1.id))
    idle? = counts.running == 0 and counts.ready > 0

    stuck =
      Enum.filter(@signal_order, fn
        :blocked_children -> blocked_children > 0
        :awaiting_verification -> counts.waiting > 0
        :idle_with_ready_work -> idle?
      end)

    %{
      epic_id: epic_id,
      counts: counts,
      total: total,
      closed: counts.closed,
      percent_complete: percent(counts.closed, total),
      blocked_children: blocked_children,
      awaiting_verification: counts.waiting,
      idle_with_ready_work: idle?,
      stuck: stuck,
      last_child_activity_at: last_activity(children)
    }
  end

  defp bucket(%{status: :closed}), do: :closed
  defp bucket(%{status: :awaiting_verification}), do: :waiting
  defp bucket(%{status: :in_progress}), do: :running
  defp bucket(child), do: if(Map.get(child, :refined) == true, do: :ready, else: :backlog)

  defp percent(_closed, 0), do: 0
  defp percent(closed, total), do: round(closed * 100 / total)

  defp last_activity([]), do: nil

  defp last_activity(children) do
    children
    |> Enum.map(&Map.get(&1, :updated_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # Ids of children held by at least one open gating edge. Two bulk reads for
  # the whole page: the gating rows touching any child, then the statuses of
  # whatever is on the far end of them.
  defp blocked_ids([]), do: MapSet.new()

  defp blocked_ids(children) do
    open_children =
      for child <- children, child.status != :closed, into: MapSet.new(), do: child.id

    if MapSet.size(open_children) == 0 do
      MapSet.new()
    else
      ids = MapSet.to_list(open_children)
      pairs = gating_pairs(ids, open_children)
      closed_blockers = closed_ids(Enum.map(pairs, &elem(&1, 1)))

      for {blocked, blocker} <- pairs,
          not MapSet.member?(closed_blockers, blocker),
          into: MapSet.new(),
          do: blocked
    end
  end

  # `{blocked_id, blocker_id}` for every gating row with a child on the blocked
  # end — the same orientation `Arbiter.Board.Snapshot.blockers_from/2` uses.
  defp gating_pairs(ids, open_children) do
    gating = DependencyGraph.gating_types()

    Dependency
    |> Ash.Query.filter(type in ^gating and (from_issue_id in ^ids or to_issue_id in ^ids))
    |> Ash.read!()
    |> Enum.flat_map(fn
      %{type: :depends_on} = dep -> [{dep.from_issue_id, dep.to_issue_id}]
      %{type: :blocks} = dep -> [{dep.to_issue_id, dep.from_issue_id}]
      _ -> []
    end)
    |> Enum.filter(fn {blocked, _blocker} -> MapSet.member?(open_children, blocked) end)
  end

  defp closed_ids([]), do: MapSet.new()

  defp closed_ids(ids) do
    ids = Enum.uniq(ids)
    closed = :closed

    Issue
    |> Ash.Query.filter(id in ^ids and status == ^closed)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> MapSet.new(& &1.id)
  end
end
