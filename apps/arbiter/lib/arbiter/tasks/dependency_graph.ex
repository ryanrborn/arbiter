defmodule Arbiter.Tasks.DependencyGraph do
  @moduledoc """
  Gating-edge normalisation and cycle detection over `Arbiter.Tasks.Dependency`
  rows.

  Extracted from `Arbiter.Workflows.Conductor` (bd-apj0gq) so the two callers
  that need it agree on one implementation:

    * `Conductor.validate_acyclic/1` — over a *graph's members only*, at kickoff.
    * `Arbiter.Tasks.Dependencies.add/4` — via `candidate_cycle/2`, over the
      **global** edge set, on every gating-edge write, so a cycle can never be
      persisted in the first place.

  ## Gating edges

  Only `:depends_on` and `:blocks` order work; every other type
  (`:relates_to`, `:discovered_from`, `:parent_of`, `:conflicts_with`) is
  non-gating and is never part of a cycle check. `:conflicts_with` in particular
  is a symmetric mutex, not an ordering edge — treating it as one would report
  phantom cycles.

  Both gating types are normalised to a single `{dependent, dependency}`
  direction ("the dependent waits for the dependency"):

      depends_on(from, to) → {from, to}
      blocks(from, to)     → {to, from}
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependency

  @gating_types [:depends_on, :blocks]

  @typedoc "A normalised gating edge: `{dependent_id, dependency_id}`."
  @type edge :: {String.t(), String.t()}

  @doc "The gating edge types (`:depends_on`, `:blocks`)."
  @spec gating_types() :: [atom()]
  def gating_types, do: @gating_types

  @doc "True when `type` orders work and therefore participates in cycles."
  @spec gating?(atom()) :: boolean()
  def gating?(type), do: type in @gating_types

  @doc """
  Every gating edge in the ledger, normalised to `{dependent, dependency}`.

  Pass `:all` for the global set, or a list of issue ids to keep only edges with
  **both** endpoints in that set (the Conductor's member-scoped view — an edge
  running through a non-member is not a cycle *within the graph*).
  """
  @spec gating_edges(:all | [String.t()]) :: [edge()]
  def gating_edges(scope \\ :all)

  def gating_edges(:all) do
    gating = @gating_types

    Dependency
    |> Ash.Query.filter(type in ^gating)
    |> Ash.read!()
    |> Enum.map(&normalize/1)
  end

  def gating_edges(member_ids) when is_list(member_ids) do
    member_set = MapSet.new(member_ids)
    gating = @gating_types

    Dependency
    |> Ash.Query.filter(type in ^gating)
    |> Ash.read!()
    |> Enum.filter(fn d ->
      MapSet.member?(member_set, d.from_issue_id) and MapSet.member?(member_set, d.to_issue_id)
    end)
    |> Enum.map(&normalize/1)
  end

  @doc """
  Normalise one gating `Dependency` (or a `{type, from, to}` triple) to a
  `{dependent, dependency}` edge.
  """
  @spec normalize(Dependency.t() | {atom(), String.t(), String.t()}) :: edge()
  def normalize(%{type: :depends_on, from_issue_id: from, to_issue_id: to}), do: {from, to}
  def normalize(%{type: :blocks, from_issue_id: from, to_issue_id: to}), do: {to, from}
  def normalize({:depends_on, from, to}), do: {from, to}
  def normalize({:blocks, from, to}), do: {to, from}

  @doc """
  Look for a cycle among `vertices` given normalised `edges`.

  Returns `:ok`, or `{:error, {:cyclic, cycle}}` where `cycle` is the closed
  walk (first id repeated at the end) naming the offenders. Vertices are probed
  in sorted order for determinism.

  This asks the *whole-graph* question ("is anything in here cyclic?"), which is
  what `Conductor.validate_acyclic/1` wants at kickoff. A write path testing one
  candidate edge wants `candidate_cycle/2` instead — see its note.
  """
  @spec detect_cycle([String.t()], [edge()]) :: :ok | {:error, {:cyclic, [String.t()]}}
  def detect_cycle(vertices, edges) do
    graph = :digraph.new()

    try do
      Enum.each(vertices, &:digraph.add_vertex(graph, &1))
      Enum.each(edges, fn {a, b} -> :digraph.add_edge(graph, a, b) end)

      vertices
      |> Enum.sort()
      |> Enum.find_value(fn vertex ->
        case :digraph.get_short_cycle(graph, vertex) do
          false -> nil
          cycle -> cycle
        end
      end)
      |> case do
        nil -> :ok
        cycle -> {:error, {:cyclic, cycle}}
      end
    after
      :digraph.delete(graph)
    end
  end

  @doc """
  The cycle a candidate `{dependent, dependency}` edge would close, if any.

  Asks the narrow question a write path actually needs: **does a path already
  run from the candidate's `dependency` back to its `dependent`?** If it does,
  adding the edge closes that path into a cycle and the closed walk is returned,
  starting and ending at `dependent`. If it does not, the edge is safe.

  Deliberately *not* `detect_cycle/2` over `[candidate | existing]`: that answers
  "is there a cycle anywhere", so one legacy cyclic pair — writable before this
  facade existed, and still reachable from seeds — would reject every unrelated
  gating write fleet-wide and name a cycle the operator never touched.

  `edges` must be the **existing** edges only; the candidate is not added.
  """
  @spec candidate_cycle(edge(), [edge()]) :: :ok | {:error, {:cyclic, [String.t()]}}
  def candidate_cycle({dependent, dependency}, edges) do
    graph = :digraph.new()

    try do
      :digraph.add_vertex(graph, dependent)
      :digraph.add_vertex(graph, dependency)

      Enum.each(edges, fn {a, b} ->
        :digraph.add_vertex(graph, a)
        :digraph.add_vertex(graph, b)
        :digraph.add_edge(graph, a, b)
      end)

      case :digraph.get_path(graph, dependency, dependent) do
        false -> :ok
        path -> {:error, {:cyclic, [dependent | path]}}
      end
    after
      :digraph.delete(graph)
    end
  end

  @doc """
  Render a closed walk as `bd-a → bd-b → bd-a`.
  """
  @spec format_cycle([String.t()]) :: String.t()
  def format_cycle(cycle) when is_list(cycle), do: Enum.join(cycle, " → ")
end
