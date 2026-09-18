defmodule Arbiter.Accounts.ProviderAccountMigrationBackup do
  @moduledoc """
  Phase P2 (`docs/provider-account-design.md` §7.5). The undo record for
  `mix arbiter.accounts.migrate`: one row per workspace whose `worker_env` the
  migration is about to modify, written **before** the modification.

  §7.5 is explicit that this must be "encrypted with the same Vault — never a
  plaintext file on disk", so `worker_env` here is `ash_cloak`-encrypted
  exactly as `Arbiter.Tasks.Workspace`'s own `worker_env` is, into an
  `encrypted_worker_env` binary column. There is no filesystem artefact of any
  kind: the backup lives and dies with the database, under the same key as the
  material it is a copy of.

  `worker_env_meta` is the public names + per-key `%{"secret" => bool}` flags
  companion (same shape as the workspace attribute). It is stored in the clear
  because it holds no values, and it is what lets
  `mix arbiter.accounts.rollback` restore a key's *secret flag* as well as its
  value through `Arbiter.Tasks.Workspace.Changes.MergeWorkerEnv`.

  ## Append-only-ish

  The only update action is `:mark_restored`. A backup's contents are never
  edited: a second migration writes a second row, and the `migration_id`
  (shared by every row one `mix arbiter.accounts.migrate` invocation writes) is
  what a rollback addresses.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  sqlite do
    table "provider_account_migration_backups"
    repo Arbiter.Repo

    references do
      reference :workspace, on_delete: :delete
    end

    custom_indexes do
      # `mix arbiter.accounts.rollback --migration-id` is the only query this
      # table serves.
      index [:migration_id], name: "provider_account_migration_backups_migration_id_index"
    end
  end

  # Encrypts the `worker_env` snapshot at rest — ash_cloak renames it to
  # `encrypted_worker_env` (binary column, public?: false). As with Workspace
  # we do NOT enable `decrypt_by_default`; callers decrypt on demand via
  # `worker_env_map/1`.
  cloak do
    vault(Arbiter.Vault)
    attributes([:worker_env])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:workspace_id, :migration_id, :removed_keys, :worker_env, :worker_env_meta]
    end

    update :mark_restored do
      require_atomic? false
      accept []
      change set_attribute(:restored_at, &DateTime.utc_now/0)
    end

    read :for_migration do
      argument :migration_id, :string, allow_nil?: false
      filter expr(migration_id == ^arg(:migration_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :migration_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true

      description "Shared by every backup one `mix arbiter.accounts.migrate` run writes; the handle `mix arbiter.accounts.rollback` takes."
    end

    attribute :removed_keys, {:array, :string} do
      allow_nil? false
      public? true
      default []

      description "The allowlisted worker_env keys this migration removed from the workspace (§7.3)."
    end

    # ash_cloak-encrypted; see the `cloak` block. The complete pre-change
    # `%{name => value}` worker env, values included — never serialised.
    attribute :worker_env, :map do
      public? false
      allow_nil? false
      default %{}

      description "The workspace's full pre-change worker_env values. Encrypted at rest."
    end

    attribute :worker_env_meta, :map do
      allow_nil? false
      public? true
      default %{}

      description "Names + per-key secret flags only (no values), so a rollback restores the flags too."
    end

    create_timestamp :created_at

    attribute :restored_at, :utc_datetime do
      public? true
      allow_nil? true

      description "Set by `mix arbiter.accounts.rollback` once this snapshot has been merged back."
    end
  end

  relationships do
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  @doc """
  Decrypts and returns the backed-up `%{name => value}` worker env.

  Mirrors `Arbiter.Tasks.Workspace.worker_env_map/1` — same column shape, same
  vault, same on-demand decryption.
  """
  @spec worker_env_map(t()) :: %{optional(String.t()) => String.t()}
  def worker_env_map(backup) do
    case Map.get(backup, :encrypted_worker_env) do
      enc when is_binary(enc) ->
        enc
        |> Base.decode64!()
        |> Arbiter.Vault.decrypt!()
        |> Ash.Helpers.non_executable_binary_to_term()

      _ ->
        %{}
    end
  end
end
