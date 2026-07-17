defmodule Arbiter.Repo.Migrations.AddWorkspaceWorkerEnv do
  @moduledoc """
  Adds the user-defined worker env var store to `workspaces`.

  Two additive, nullable/defaulted columns back `Arbiter.Tasks.Workspace`:

    * `encrypted_worker_env` (binary) — the Base64-wrapped ciphertext of the
      `%{name => value}` map, encrypted at rest via `ash_cloak` / `Arbiter.Vault`
      (AES-256-GCM). Never read in the clear by the data layer; decryption
      happens in `Workspace.worker_env_map/1`. Mirrors `encrypted_secrets`.
    * `worker_env_meta` (map, default `%{}`) — public names + per-key secret
      flags only (`%{"NAME" => %{"secret" => bool}}`), never values. Backs
      `Workspace.worker_env_keys/1` and the API/dashboard.

  Existing rows get `NULL` / `%{}` (treated as "no worker env vars"), so this is
  a zero-downtime, forward-only change with a clean rollback.
  """

  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :worker_env_meta, :map, null: false, default: %{}
      add :encrypted_worker_env, :binary
    end
  end

  def down do
    alter table(:workspaces) do
      remove :encrypted_worker_env
      remove :worker_env_meta
    end
  end
end
