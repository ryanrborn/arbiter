defmodule Arbiter.Tasks.DependencyGraph do
  @moduledoc """
  Gating-edge normalisation and cycle detection over `Arbiter.Tasks.Dependency`
  rows.

  Extracted from `Arbiter.Workflows.Conductor` (bd-apj0gq) so the two callers
  that need it agree on one implementation:

    * `Conductor.validate_acyclic/1` — over a *graph's members only*, at kickoff.
    * `Arbiter.Tasks.Dependencies.add/4` — over the **global** edge set, on every
      gating-edge write, so a cycle can never be persisted in the first place.

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
  walk (first id repeated at the end) naming the offenders.

  Vertices are probed in sorted order for determinism. `opts[:start_with]`
  moves the given ids to the front of that probe order, so a caller testing a
  *candidate* edge gets the cycle reported from its own endpoint rather than
  from whichever id happens to sort first.
  """
  @spec detect_cycle([String.t()], [edge()], keyword()) ::
          :ok | {:error, {:cyclic, [String.t()]}}
  def detect_cycle(vertices, edges, opts \\ []) do
    graph = :digraph.new()

    try do
      Enum.each(vertices, &:digraph.add_vertex(graph, &1))
      Enum.each(edges, fn {a, b} -> :digraph.add_edge(graph, a, b) end)

      vertices
      |> probe_order(Keyword.get(opts, :start_with, []))
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
  Render a closed walk as `bd-a → bd-b → bd-a`.
  """
  @spec format_cycle([String.t()]) :: String.t()
  def format_cycle(cycle) when is_list(cycle), do: Enum.join(cycle, " → ")

  # Preferred vertices first (deduplicated, order preserved), then the rest
  # sorted so the result is stable across runs.
  defp probe_order(vertices, []), do: Enum.sort(vertices)

  defp probe_order(vertices, preferred) do
    vertex_set = MapSet.new(vertices)
    first = preferred |> Enum.uniq() |> Enum.filter(&MapSet.member?(vertex_set, &1))
    rest = vertices |> Enum.sort() |> Enum.reject(&(&1 in first))
    first ++ rest
  end
end
