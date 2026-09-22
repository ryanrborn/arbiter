defmodule Arbiter.Tasks.EdgeGate do
  @moduledoc """
  One answer to "may this task be dispatched now, given its edges and what is
  already in flight?".

  `Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler` →
  `Arbiter.Board.Autopilot` drives the board's Ready queue, and since
  bd-a14qd1 it is the only dispatcher. Arbiter used to have a second one (a
  per-graph engine), which answered the edge question separately and had
  drifted: it honoured `:conflicts_with`, the board had never heard of it, and
  a coordinator that set the mutex on two Ready tasks got both dispatched 19
  seconds apart (bd-6bax7s). This module is the single predicate every
  dispatch-time edge question goes through, so no future caller can drift from
  the board again.

  ## The edge types, and what each one does here

    * `:depends_on` / `:blocks` — **gating**. They order work: the dependent
      waits until its dependency is `:closed`. Normalised by
      `Arbiter.Tasks.DependencyGraph`, and the only types that participate in
      cycle checks.
    * `:conflicts_with` — a **symmetric mutex**. It does not order anything, so
      a task carrying one is still *ready*; it simply may not be dispatched
      while its counterpart is in flight. Stored in one direction and honoured
      in both.
    * `:parent_of`, `:relates_to`, `:discovered_from` — **non-gating**. They
      carry meaning for humans and rollups (`Arbiter.Tasks.ParentRefs`,
      `Arbiter.Tasks.EpicRollup`) and never hold a dispatch back.

  `mutex_types/0` and `non_gating_types/0` sit alongside
  `DependencyGraph.gating_types/0` so the three partition
  `Arbiter.Tasks.Dependency.types/0` exactly — a newly-invented edge type
  fails that test rather than silently defaulting to "non-gating".

  ## `:closed`, not "finished"

  `blockers/2` keeps a blocker until it is `:closed`, which means a task parked
  at `:awaiting_verification` (merged, waiting on a coordinator's post-deploy
  check) **still blocks its dependents**. That is deliberate and long-standing:
  the dependent's premise is that the upstream change is known-good, and
  `:awaiting_verification` is exactly the state where that is not yet known.
  `Arbiter.Tasks.Issue.ready/0` applies the same rule, so all three surfaces
  agree.

  A `:conflicts_with` counterpart is the opposite question — "is it in flight
  *right now*" — and `:awaiting_verification` answers no: the work merged, the
  worktree is gone, nothing can collide with it. In-flight-ness is the
  caller's to determine (the board reads live workers) and arrives here as
  `:claimed`.

  ## Shape

  `gate/1` is pure and takes one card's context:

      EdgeGate.gate(%{blocked_by: ["bd-9"], conflicts: ["bd-2"], claimed: ["bd-2"]})
      #=> {:blocked, {:waiting_on, ["bd-9"]}}

  It reports the block, not the prose: `describe/1` phrases it, and each caller
  decorates (the board prefixes `blocked — ` and names the counterpart's
  state). An open blocker outranks a
  conflict because it survives the conflict clearing — telling an operator
  "conflicts with bd-2" when the card is also waiting on an unmerged
  dependency would send them to finish bd-2 for nothing.
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph

  @mutex_types [:conflicts_with]
  @non_gating_types [:relates_to, :discovered_from, :parent_of]

  @typedoc "A `Dependency` row, or anything with the same three fields."
  @type dep :: %{
          required(:type) => atom(),
          required(:from_issue_id) => String.t(),
          required(:to_issue_id) => String.t(),
          optional(any()) => any()
        }

  @typedoc "Symmetric `:conflicts_with` adjacency: `%{id => MapSet(peers)}`."
  @type adjacency :: %{optional(String.t()) => MapSet.t(String.t())}

  @typedoc "Why a task may not go yet."
  @type block :: {:waiting_on, [String.t()]} | {:conflicts_with, String.t()}

  @type decision :: :ok | {:blocked, block()}

  @typedoc """
  One card's edge context. `:blocked_by` is its still-open gating blockers,
  `:conflicts` its `:conflicts_with` counterparts, `:claimed` the ids already
  in flight (or already promoted in this same pass).
  """
  @type ctx :: %{
          optional(:blocked_by) => [String.t()] | nil,
          optional(:conflicts) => [String.t()] | MapSet.t(String.t()) | nil,
          optional(:claimed) => [String.t()] | MapSet.t(String.t()) | map() | nil,
          optional(any()) => any()
        }

  @doc "The edge types that order work (`:depends_on`, `:blocks`)."
  @spec gating_types() :: [atom()]
  def gating_types, do: DependencyGraph.gating_types()

  @doc "The mutual-exclusion edge types (`:conflicts_with`)."
  @spec mutex_types() :: [atom()]
  def mutex_types, do: @mutex_types

  @doc "The edge types that never hold a dispatch back."
  @spec non_gating_types() :: [atom()]
  def non_gating_types, do: @non_gating_types

  @doc """
  May this task be dispatched, given its edges and what is already claimed?

  Returns `:ok`, or `{:blocked, block}` naming the reason. See the moduledoc
  for `ctx`'s shape and why an open blocker outranks a conflict.
  """
  @spec gate(ctx()) :: decision()
  def gate(ctx) when is_map(ctx) do
    case open_blockers(ctx) do
      [] -> conflict_block(ctx)
      ids -> {:blocked, {:waiting_on, ids}}
    end
  end

  @doc """
  Phrase a block the way the board already phrases a dependency wait.

      iex> Arbiter.Tasks.EdgeGate.describe({:waiting_on, ["bd-8", "bd-9"]})
      "waiting on bd-8, bd-9"

      iex> Arbiter.Tasks.EdgeGate.describe({:conflicts_with, "bd-2"})
      "conflicts with bd-2"
  """
  @spec describe(block()) :: String.t()
  def describe({:waiting_on, ids}), do: "waiting on " <> Enum.join(ids, ", ")
  def describe({:conflicts_with, peer}), do: "conflicts with " <> peer

  @doc """
  Open gating blockers per issue: `%{blocked_id => [blocker_id]}`.

  `:depends_on` targets and `:blocks` sources that are not themselves
  `:closed`, keyed by the issue they hold back. Only issues that are still
  `:open` get an entry — a blocker on something already in progress is not a
  dispatch question. Pure: hand it the dependency rows and the issues.

  Mirrors `Arbiter.Tasks.Issue.ready/0`'s gating rule, but keeps the blocked
  ids instead of dropping them, because the board has to show *why* a card
  can't go.
  """
  @spec blockers([dep()], [map()]) :: %{optional(String.t()) => [String.t()]}
  def blockers(deps, issues) do
    open_ids = for i <- issues, i.status == :open, into: MapSet.new(), do: i.id
    closed = for i <- issues, i.status == :closed, into: MapSet.new(), do: i.id

    deps
    |> Enum.flat_map(&DependencyGraph.normalize_gating/1)
    |> Enum.filter(fn {blocked, blocker} ->
      MapSet.member?(open_ids, blocked) and not MapSet.member?(closed, blocker)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, blockers} -> {id, blockers |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc """
  The `:conflicts_with` rows as stored, `{from_issue_id, to_issue_id}`.

  The direction is meaningless (the edge is symmetric) but preserved, so a
  caller can pass the pairs through a pure boundary and build the adjacency on
  the other side with `adjacency/1`.
  """
  @spec conflict_pairs([dep()]) :: [{String.t(), String.t()}]
  def conflict_pairs(deps) do
    for %{type: :conflicts_with} = d <- deps, do: {d.from_issue_id, d.to_issue_id}
  end

  @doc """
  Symmetric conflict adjacency from dependency rows.

  Pass `:all` for the global set, or a list of issue ids to keep only edges
  with **both** endpoints in that set — a mutex running through an id outside
  the scope is not that scope's to serialize.
  """
  @spec conflict_adjacency([dep()], :all | [String.t()]) :: adjacency()
  def conflict_adjacency(deps, scope \\ :all) do
    deps |> conflict_pairs() |> adjacency(scope)
  end

  @doc "Build symmetric adjacency from `{a, b}` pairs. See `conflict_adjacency/2`."
  @spec adjacency([{String.t(), String.t()}], :all | [String.t()]) :: adjacency()
  def adjacency(pairs, scope \\ :all) do
    keep? = scope_filter(scope)

    Enum.reduce(pairs, %{}, fn {a, b}, acc ->
      if keep?.(a) and keep?.(b) do
        acc |> add_peer(a, b) |> add_peer(b, a)
      else
        acc
      end
    end)
  end

  @doc "This id's conflict counterparts, sorted."
  @spec conflicts(adjacency(), String.t()) :: [String.t()]
  def conflicts(adjacency, id) do
    case Map.get(adjacency, id) do
      nil -> []
      peers -> peers |> MapSet.to_list() |> Enum.sort()
    end
  end

  @doc """
  Read the `:conflicts_with` rows and build the adjacency. The one impure
  entry point; `conflict_adjacency/2` is the pure half.
  """
  @spec load_conflict_adjacency(:all | [String.t()]) :: adjacency()
  def load_conflict_adjacency(scope \\ :all) do
    mutex = @mutex_types

    Dependency
    |> Ash.Query.filter(type in ^mutex)
    |> Ash.read!()
    |> conflict_adjacency(scope)
  end

  # ---- internals ----------------------------------------------------------

  defp open_blockers(ctx) do
    ctx |> Map.get(:blocked_by) |> List.wrap() |> Enum.uniq() |> Enum.sort()
  end

  # The first claimed counterpart in sorted order — deterministic, so the
  # reason on a card doesn't shuffle between renders of the same board.
  defp conflict_block(ctx) do
    claimed = claimed_set(Map.get(ctx, :claimed))

    ctx
    |> Map.get(:conflicts)
    |> to_sorted_ids()
    |> Enum.find(&MapSet.member?(claimed, &1))
    |> case do
      nil -> :ok
      peer -> {:blocked, {:conflicts_with, peer}}
    end
  end

  defp claimed_set(nil), do: MapSet.new()
  defp claimed_set(%MapSet{} = set), do: set
  defp claimed_set(claimed) when is_list(claimed), do: MapSet.new(claimed)
  defp claimed_set(claimed) when is_map(claimed), do: claimed |> Map.keys() |> MapSet.new()

  defp to_sorted_ids(nil), do: []
  defp to_sorted_ids(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp to_sorted_ids(ids) when is_list(ids), do: Enum.sort(ids)

  defp scope_filter(:all), do: fn _ -> true end

  defp scope_filter(ids) when is_list(ids) do
    set = MapSet.new(ids)
    &MapSet.member?(set, &1)
  end

  defp add_peer(map, a, b), do: Map.update(map, a, MapSet.new([b]), &MapSet.put(&1, b))
end
