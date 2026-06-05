defmodule Arbiter.Beads.Convoy.Calcs do
  @moduledoc """
  Batch calculations for Convoy that replace aggregate counts.

  SQLite does not support inline aggregates on many-to-many relationships in
  ash_sqlite 0.2.x. These module-based calculations use Ash.count! (which IS
  supported via the {:query_aggregate, :count} path) and batch across all
  convoys in the load to avoid N+1 queries.
  """

  require Ash.Query

  defmodule TotalIssues do
    @moduledoc false
    use Ash.Resource.Calculation

    def calculate(convoys, _, _) do
      require Ash.Query
      convoy_ids = Enum.map(convoys, & &1.id)

      memberships =
        Arbiter.Beads.ConvoyMembership
        |> Ash.Query.filter(convoy_id in ^convoy_ids)
        |> Ash.read!()

      counts = Enum.frequencies_by(memberships, & &1.convoy_id)
      {:ok, Enum.map(convoys, fn c -> Map.get(counts, c.id, 0) end)}
    end
  end

  defmodule ClosedIssues do
    @moduledoc false
    use Ash.Resource.Calculation

    def calculate(convoys, _, _) do
      require Ash.Query
      convoy_ids = Enum.map(convoys, & &1.id)

      memberships =
        Arbiter.Beads.ConvoyMembership
        |> Ash.Query.filter(convoy_id in ^convoy_ids)
        |> Ash.Query.load(:issue)
        |> Ash.read!()

      closed_counts =
        memberships
        |> Enum.filter(fn m -> m.issue && m.issue.status == :closed end)
        |> Enum.frequencies_by(& &1.convoy_id)

      {:ok, Enum.map(convoys, fn c -> Map.get(closed_counts, c.id, 0) end)}
    end
  end
end
