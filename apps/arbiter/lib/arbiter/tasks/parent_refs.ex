defmodule Arbiter.Tasks.ParentRefs do
  @moduledoc """
  What a child issue needs in order to say what it is part of.

  Design bd-2s901b §7 (ticket bd-38of5i). The detail page renders
  `↳ Part of bd-cv1inp — Browser coordinator sessions • 9/14 closed` under the
  title; this is the read behind it. It returns plain maps, not `%Issue{}`s,
  because `ArbiterWeb.ParentLink` renders the same shape for the board's
  compact chip — and the board builds its refs inside `Arbiter.Board.Snapshot`,
  which never touches a repo.

  Each ref:

      %{
        id: "bd-cv1inp",
        title: "Browser coordinator sessions",
        issue_type: :epic,
        status: :open,
        child_total: 14,
        child_closed: 9,
        # the other workspace's name, or nil when the parent is local
        workspace_name: nil,
        # `{index, total}`, or nil when the sibling order is ambiguous
        position: nil
      }

  ## The sibling position, and why it is usually nil

  §7 asks for an optional "3 of 14", and is explicit that it must be omitted
  rather than faked. `child_total` is free, but an *index* needs an ordering,
  and children of an epic generally have none: they are a set, not a list.
  Creation order is not it — an epic's children are filed in whatever order
  someone thought of them, so "3 of 14" off a timestamp would read as a
  sequence the operator is meant to follow and isn't one.

  So the only ordering this trusts is one the operator actually declared: the
  siblings' `depends_on` / `blocks` edges forming a **single unbroken chain**
  over *every* child. A fork, a join, a cycle, a partial chain or no edges at
  all all resolve to `nil` and the banner simply doesn't mention a position.
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @gating_types [:depends_on, :blocks]

  @type ref :: %{
          id: String.t(),
          title: String.t() | nil,
          issue_type: atom(),
          status: atom(),
          child_total: non_neg_integer(),
          child_closed: non_neg_integer(),
          workspace_name: String.t() | nil,
          position: {pos_integer(), pos_integer()} | nil
        }

  @doc """
  Every `parent_of` parent of `child`, most recently updated first.

  Most issues have none and get `[]`; more than one is unusual but legal, and
  the banner stacks them rather than picking one arbitrarily. Best-effort: an
  unreadable edge set is no banner, never a raise on a page that renders fine
  without one.
  """
  @spec for_issue(Issue.t()) :: [ref()]
  def for_issue(%Issue{} = child) do
    child.id
    |> Dependencies.for_issue()
    |> Map.get(:parents, [])
    |> Enum.map(& &1.issue)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&recency/1, {:desc, DateTime})
    |> Enum.map(&ref(&1, child))
  rescue
    _ -> []
  end

  def for_issue(_), do: []

  @doc """
  The 1-based position of `child_id` among `sibling_ids`, and the total — but
  only when the gating edges among the siblings form one unbroken chain over
  all of them.

  `gating_pairs` are `{blocked_id, blocker_id}`: the blocker comes first in the
  chain. Pairs naming anything outside `sibling_ids` are ignored rather than
  counted against the chain, so an epic's children can depend on work outside
  the epic without losing their order.

  Returns `nil` for anything ambiguous — a fork, a join, a cycle, a partial
  chain, no edges at all, or an only child.
  """
  @spec chain_position(String.t(), [String.t()], [{String.t(), String.t()}]) ::
          {pos_integer(), pos_integer()} | nil
  def chain_position(child_id, sibling_ids, gating_pairs) do
    siblings = MapSet.new(sibling_ids)

    edges =
      gating_pairs
      |> Enum.filter(fn {blocked, blocker} ->
        blocked != blocker and MapSet.member?(siblings, blocked) and
          MapSet.member?(siblings, blocker)
      end)
      |> Enum.uniq()

    with true <- MapSet.size(siblings) > 1,
         true <- MapSet.member?(siblings, child_id),
         # A path over n nodes has exactly n-1 edges, and no node is either
         # blocked twice or a blocker twice. Together with the walk below,
         # that rules out every shape but a single simple path.
         true <- length(edges) == MapSet.size(siblings) - 1,
         true <- distinct?(edges, &elem(&1, 0)),
         true <- distinct?(edges, &elem(&1, 1)),
         {:ok, order} <- walk(siblings, edges) do
      {Enum.find_index(order, &(&1 == child_id)) + 1, length(order)}
    else
      _ -> nil
    end
  end

  # ---- internals -----------------------------------------------------------

  defp ref(%Issue{} = parent, %Issue{} = child) do
    parent = load_rollup(parent)
    sibling_ids = child_ids(parent.id)

    %{
      id: parent.id,
      title: parent.title,
      issue_type: parent.issue_type,
      status: parent.status,
      child_total: parent.child_total || length(sibling_ids),
      child_closed: parent.child_closed || 0,
      workspace_name: foreign_workspace_name(parent, child),
      position: chain_position(child.id, sibling_ids, gating_pairs(sibling_ids))
    }
  end

  defp load_rollup(%Issue{} = parent) do
    case Ash.load(parent, [:child_total, :child_closed]) do
      {:ok, loaded} -> loaded
      _ -> parent
    end
  end

  defp child_ids(parent_id) do
    parent_id
    |> Dependencies.for_issue()
    |> Map.get(:children, [])
    |> Enum.map(& &1.issue_id)
    |> Enum.uniq()
  end

  # `{blocked, blocker}` for every gating edge touching a sibling. Read in one
  # query; `chain_position/3` drops the ones that leave the sibling set.
  defp gating_pairs([]), do: []

  defp gating_pairs(sibling_ids) do
    Dependency
    |> Ash.Query.filter(
      type in ^@gating_types and
        (from_issue_id in ^sibling_ids or to_issue_id in ^sibling_ids)
    )
    |> Ash.read!()
    |> Enum.map(fn
      %Dependency{type: :depends_on} = dep -> {dep.from_issue_id, dep.to_issue_id}
      %Dependency{type: :blocks} = dep -> {dep.to_issue_id, dep.from_issue_id}
    end)
  rescue
    _ -> []
  end

  # The banner tags the parent's workspace only when it is not the child's —
  # naming the workspace on every local edge would be noise on every page.
  defp foreign_workspace_name(%Issue{workspace_id: ws}, %Issue{workspace_id: ws}), do: nil

  defp foreign_workspace_name(%Issue{workspace_id: ws_id}, _child) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{name: name}} -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp foreign_workspace_name(_parent, _child), do: nil

  defp recency(%Issue{updated_at: %DateTime{} = updated_at}), do: updated_at
  defp recency(%Issue{created_at: %DateTime{} = created_at}), do: created_at
  defp recency(_), do: ~U[1970-01-01 00:00:00Z]

  defp distinct?(edges, fun),
    do: edges |> Enum.map(fun) |> Enum.uniq() |> length() == length(edges)

  # Follow the chain from its head — the one sibling nothing else comes before
  # it, i.e. the one that is never the blocked end. A cycle has no such head
  # and stops here; a shape that has one but doesn't reach every sibling stops
  # at the length check.
  defp walk(siblings, edges) do
    blocked = MapSet.new(edges, &elem(&1, 0))
    next = Map.new(edges, fn {blocked_id, blocker_id} -> {blocker_id, blocked_id} end)

    case Enum.filter(siblings, &(not MapSet.member?(blocked, &1))) do
      [head] -> follow(head, next, MapSet.size(siblings))
      _ -> :error
    end
  end

  defp follow(head, next, expected) do
    order =
      head
      |> Stream.unfold(fn
        nil -> nil
        id -> {id, Map.get(next, id)}
      end)
      |> Enum.take(expected)

    if length(order) == expected and length(Enum.uniq(order)) == expected,
      do: {:ok, order},
      else: :error
  end
end
