defmodule Arbiter.Repo.Migrations.CreateAnthropicQuotas do
  @moduledoc """
  Per-workspace Anthropic quota snapshots (bd-5boun6). One row per
  workspace+provider; the local proxy upserts onto the unique index.
  """

  use Ecto.Migration

  def up do
    create table(:anthropic_quotas, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :workspace_id, :text, null: false
      add :provider, :text, null: false, default: "claude"
      add :utilization_5h, :float
      add :reset_5h_at, :utc_datetime
      add :status_5h, :text
      add :utilization_7d, :float
      add :reset_7d_at, :utc_datetime
      add :status_7d, :text
      add :representative_claim, :text
      add :overage_status, :text
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # One snapshot per workspace+provider — the proxy upserts onto this identity.
    create unique_index(:anthropic_quotas, [:workspace_id, :provider],
             name: "anthropic_quotas_workspace_provider_index"
           )
  end

  def down do
    drop_if_exists unique_index(:anthropic_quotas, [:workspace_id, :provider],
                     name: "anthropic_quotas_workspace_provider_index"
                   )

    drop table(:anthropic_quotas)
  end
end
