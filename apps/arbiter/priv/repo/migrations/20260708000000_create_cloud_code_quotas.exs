defmodule Arbiter.Repo.Migrations.CreateCloudCodeQuotas do
  @moduledoc """
  Per-workspace Gemini CLI / Antigravity (Google Cloud Code Assist) quota
  snapshots (bd-ajh7bd). One row per `{workspace_id, provider}`;
  `Arbiter.Quota.CloudCode.refresh/3` upserts onto the unique index from a
  direct call to the Cloud Code Assist API.

  Google reports a per-model `remainingFraction` rather than time windows, so
  the row keeps the full serialized snapshot (per-model list) in `snapshot`
  plus a single representative `used_percent` / `reset_at` for the topbar bar.
  """

  use Ecto.Migration

  def up do
    create table(:cloud_code_quotas, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :workspace_id, :text, null: false
      add :provider, :text, null: false
      add :plan, :text
      add :message, :text
      add :used_percent, :float
      add :reset_at, :utc_datetime
      add :snapshot, :map
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:cloud_code_quotas, [:workspace_id, :provider],
             name: "cloud_code_quotas_workspace_provider_index"
           )
  end

  def down do
    drop_if_exists unique_index(:cloud_code_quotas, [:workspace_id, :provider],
                     name: "cloud_code_quotas_workspace_provider_index"
                   )

    drop table(:cloud_code_quotas)
  end
end
