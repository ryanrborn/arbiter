defmodule Arbiter.Repo.Migrations.AddProviderAccountToUsageEvents do
  @moduledoc """
  Phase P9 of `docs/provider-account-design.md` (§8, bd-al9qqe): adds
  `provider_account_id` and `provider_credential_id` (both nullable uuid) to
  `usage_events`, then backfills `provider_account_id` from
  `workspace_provider_accounts` for existing rows — see
  `Arbiter.Usage.ProviderAccountBackfill` for the exact rule and its known
  limitation (a workspace's account assignment changing mid-history).

  `provider_credential_id` is deliberately **not** backfilled: it names the
  specific credential a spend was made under, and nothing on a pre-P9 row
  records which credential (if any) a spawn actually carried — guessing one
  would fabricate the exact fact §2.5 says this column exists to preserve.
  """

  use Ecto.Migration

  def up do
    alter table(:usage_events) do
      add :provider_account_id, :uuid
      add :provider_credential_id, :uuid
    end

    create index(:usage_events, [:provider_account_id, :occurred_at])

    flush()

    %{before: before, backfilled: backfilled, unresolved: unresolved} =
      Arbiter.Usage.ProviderAccountBackfill.run()

    IO.puts(
      "[add_provider_account_to_usage_events] usage_events: #{before} row(s) had a NULL " <>
        "provider_account_id; backfilled #{backfilled}; #{unresolved} unresolvable remaining " <>
        "(no workspace, or the workspace has no linked account for that provider)."
    )
  end

  def down do
    drop_if_exists index(:usage_events, [:provider_account_id, :occurred_at])

    alter table(:usage_events) do
      remove :provider_credential_id
      remove :provider_account_id
    end
  end
end
