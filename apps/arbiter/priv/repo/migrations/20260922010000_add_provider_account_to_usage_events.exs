defmodule Arbiter.Repo.Migrations.AddProviderAccountToUsageEvents do
  @moduledoc """
  P11 (`docs/provider-account-design.md` §2.5, bd-8zvh5a): `arb account merge`
  re-points `usage_events.provider_account_id` from the merged-away account to
  the survivor, per §2.5's table. That re-point (and the retroactive-rollup
  test it powers) needs the column to exist.

  This is a minimal slice of P9 (bd-al9qqe, "usage_events.provider_account_id
  + provider_credential_id + backfill") — nullable columns only, **no
  backfill**. Populating historical rows for every pre-existing event is P9's
  scope; this ticket only needs new/merged rows to carry the account so a
  merge has something to re-point. Coordinated with P9 via `arb message`
  (2026-09-22) to avoid a colliding migration.
  """

  use Ecto.Migration

  def change do
    alter table(:usage_events) do
      add :provider_account_id, :uuid
      add :provider_credential_id, :uuid
    end

    create index(:usage_events, [:provider_account_id])
  end
end
