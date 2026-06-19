defmodule Arbiter.Beads.Issue.Calcs do
  @moduledoc """
  Batch calculations for the parent-with-progress rollup.

  A bead is a *parent* of every bead it points at with a `:parent_of`
  dependency edge (`from_issue` is the parent, `to_issue` the child — see
  `Arbiter.Beads.Dependency`). These calculations roll the children up into a
  `{closed, total}` progress pair on the parent:

    * `child_total`  — count of `:parent_of` children
    * `child_closed` — count of those children whose status is `:closed`

  Callers compose a "progress" map: `%{closed: child_closed, total: child_total}`.

  This replaces the old `Convoy`/`ConvoyMembership` aggregates: a tracked
  grouping is now just a normal bead with `:parent_of` children. Like the old
  Convoy calcs, these are module calculations rather than inline aggregates —
  SQLite (ash_sqlite 0.2.x) does not support inline aggregates across the
  dependency join — so they batch across every parent in the load to avoid an
  N+1 over `Ash.read!`.
  """

  require Ash.Query

  defmodule ChildTotal do
    @moduledoc false
    use Ash.Resource.Calculation

    def calculate(issues, _opts, _context) do
      require Ash.Query
      parent_of = :parent_of
      ids = Enum.map(issues, & &1.id)

      edges =
        Arbiter.Beads.Dependency
        |> Ash.Query.filter(type == ^parent_of and from_issue_id in ^ids)
        |> Ash.read!()

      counts = Enum.frequencies_by(edges, & &1.from_issue_id)
      {:ok, Enum.map(issues, fn i -> Map.get(counts, i.id, 0) end)}
    end
  end

  defmodule ChildClosed do
    @moduledoc false
    use Ash.Resource.Calculation

    def calculate(issues, _opts, _context) do
      require Ash.Query
      parent_of = :parent_of
      ids = Enum.map(issues, & &1.id)

      edges =
        Arbiter.Beads.Dependency
        |> Ash.Query.filter(type == ^parent_of and from_issue_id in ^ids)
        |> Ash.Query.load(:to_issue)
        |> Ash.read!()

      closed_counts =
        edges
        |> Enum.filter(fn e -> e.to_issue && e.to_issue.status == :closed end)
        |> Enum.frequencies_by(& &1.from_issue_id)

      {:ok, Enum.map(issues, fn i -> Map.get(closed_counts, i.id, 0) end)}
    end
  end
end
