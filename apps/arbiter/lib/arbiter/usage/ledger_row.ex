defmodule Arbiter.Usage.LedgerRow do
  @moduledoc """
  A read-only Ecto projection of `usage_events` (the same table
  `Arbiter.Usage.Event` owns as an Ash resource) used only to build grouped
  `SUM(cost_usd) ... GROUP BY` aggregates directly through `Ecto.Query` —
  see `Arbiter.Usage.spend_by_account/1` and `spend_by_workspace/1`. Never
  written through; every insert/update still goes through the Ash resource.
  """
  use Ecto.Schema

  @primary_key false
  schema "usage_events" do
    field :provider_account_id, Ecto.UUID
    field :workspace_id, :string
    field :provider, :string
    field :cost_usd, :float
    field :occurred_at, :utc_datetime_usec
  end
end
