defmodule Arbiter.Repo.Migrations.CreateProviderAccountMigrationBackups do
  @moduledoc """
  Phase P2 of the provider-accounts migration (`docs/provider-account-design.md`
  §7.5, bd-77j2if): creates `provider_account_migration_backups`, the undo
  record `mix arbiter.accounts.migrate` writes before it touches a workspace's
  `worker_env`, and `mix arbiter.accounts.rollback` reads back.

  `encrypted_worker_env` is an `ash_cloak` blob under `Arbiter.Vault` — the
  same column shape and the same key as `workspaces.encrypted_worker_env`,
  which is the point: §7.5 requires the backup be encrypted material in the
  database, never a plaintext file on disk.

  Hand-written rather than via `mix ash.codegen`, for the reason the P1
  migration (`20260913074116_create_provider_accounts.exs`) records: this
  repo's committed `priv/resource_snapshots` have drifted from several
  hand-written migrations, so a codegen run tries to "catch up" unrelated
  tables in the same file.

  This migration is purely additive; `down` drops the table and no other data
  is touched. That is §7.5's "Release N" rollback, with zero data loss.
  """

  use Ecto.Migration

  def up do
    create table(:provider_account_migration_backups, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "provider_account_migration_backups_workspace_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :migration_id, :text, null: false
      add :removed_keys, {:array, :text}, null: false, default: []
      add :encrypted_worker_env, :binary, null: false
      add :worker_env_meta, :map, null: false, default: %{}

      add :created_at, :utc_datetime_usec, null: false
      add :restored_at, :utc_datetime
    end

    create index(:provider_account_migration_backups, [:migration_id],
             name: "provider_account_migration_backups_migration_id_index"
           )
  end

  def down do
    drop_if_exists index(:provider_account_migration_backups, [:migration_id],
                     name: "provider_account_migration_backups_migration_id_index"
                   )

    drop table(:provider_account_migration_backups)
  end
end
