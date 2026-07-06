defmodule Arbiter.Repo.Migrations.CreateCodexQuotas do
  @moduledoc """
  Per-workspace Codex (OpenAI) quota snapshots (bd-cqfn5i). One row per
  workspace+provider; `Arbiter.Quota.Codex.fetch/2` upserts onto the unique
  index from a direct call to OpenAI's rate-limit endpoint.

  Codex reports two windows — `session` (primary) and `weekly` (secondary) —
  so this table names its columns for those windows rather than borrowing the
  Anthropic table's 5h/7d shape.
  """

  use Ecto.Migration

  def up do
    create table(:codex_quotas, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :workspace_id, :text, null: false
      add :provider, :text, null: false, default: "codex"
      add :plan, :text
      add :session_used_percent, :float
      add :session_reset_at, :utc_datetime
      add :weekly_used_percent, :float
      add :weekly_reset_at, :utc_datetime
      add :limit_reached, :boolean
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # One snapshot per workspace+provider — fetch/2 upserts onto this identity.
    create unique_index(:codex_quotas, [:workspace_id, :provider],
             name: "codex_quotas_workspace_provider_index"
           )
  end

  def down do
    drop_if_exists unique_index(:codex_quotas, [:workspace_id, :provider],
                     name: "codex_quotas_workspace_provider_index"
                   )

    drop table(:codex_quotas)
  end
end
