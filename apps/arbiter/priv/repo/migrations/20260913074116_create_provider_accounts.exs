defmodule Arbiter.Repo.Migrations.CreateProviderAccounts do
  @moduledoc """
  Phase P1 of the provider-accounts migration (`docs/provider-account-design.md`
  §3, bd-4qa1iw): creates `provider_accounts`, `provider_credentials`, and
  `workspace_provider_accounts`. **Tables only — nothing reads them yet.**

  Written by hand rather than via `mix ash.codegen`: this repo's committed
  `priv/resource_snapshots` have drifted from several existing hand-written
  migrations (e.g. `usage_events`, `worker_runs`, `skills` all carry columns
  with no matching snapshot), so a codegen run here tries to "catch up" every
  drifted resource in one migration — including a `usage_events` index drop, a
  `graph_members` FK rebuild that isn't supported on SQLite, and a stray
  `raise` that would abort `up` immediately. None of that belongs in a P1
  ticket scoped to three new tables, so this migration (and its matching
  `priv/resource_snapshots/repo/{provider_accounts,provider_credentials,
  workspace_provider_accounts}` snapshots) were extracted from the generated
  output by hand, leaving the pre-existing drift for whichever ticket touches
  those tables next to resolve.
  """

  use Ecto.Migration

  def up do
    create table(:provider_accounts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :provider, :text, null: false
      add :slug, :text, null: false
      add :label, :text
      add :plan, :text
      add :provider_account_ref, :text
      add :provider_org_ref, :text
      add :identity_source, :text, null: false
      add :identity_verified_at, :utc_datetime
      add :max_concurrent, :bigint
      add :quota_config, :map, default: %{}
      add :enabled, :boolean, null: false
      add :merged_into_id, :uuid

      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:provider_accounts, [:provider, :slug],
             name: "provider_accounts_provider_slug_index"
           )

    create table(:provider_credentials, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :provider_account_id,
          references(:provider_accounts,
            column: :id,
            name: "provider_credentials_provider_account_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :kind, :text, null: false
      add :env_var, :text, null: false
      add :encrypted_secret, :binary, null: false
      add :fingerprint, :text, null: false
      add :active, :boolean, null: false
      add :scopes, {:array, :text}

      add :created_at, :utc_datetime_usec, null: false
      add :retired_at, :utc_datetime
    end

    create index(:provider_credentials, [:provider_account_id, :kind],
             unique: true,
             where: "active = true",
             name: "provider_credentials_unique_active_index"
           )

    create table(:workspace_provider_accounts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "workspace_provider_accounts_workspace_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :provider, :text, null: false

      add :provider_account_id,
          references(:provider_accounts,
            column: :id,
            name: "workspace_provider_accounts_provider_account_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :share, :bigint
    end

    create unique_index(:workspace_provider_accounts, [:workspace_id, :provider],
             name: "workspace_provider_accounts_workspace_provider_index"
           )
  end

  def down do
    drop_if_exists unique_index(:workspace_provider_accounts, [:workspace_id, :provider],
                     name: "workspace_provider_accounts_workspace_provider_index"
                   )

    drop table(:workspace_provider_accounts)

    drop_if_exists index(:provider_credentials, [:provider_account_id, :kind],
                     name: "provider_credentials_unique_active_index"
                   )

    drop table(:provider_credentials)

    drop_if_exists unique_index(:provider_accounts, [:provider, :slug],
                     name: "provider_accounts_provider_slug_index"
                   )

    drop table(:provider_accounts)
  end
end
