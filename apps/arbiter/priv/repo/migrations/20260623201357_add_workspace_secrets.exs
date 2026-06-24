defmodule Arbiter.Repo.Migrations.AddWorkspaceSecrets do
  @moduledoc """
  Adds the encrypted `encrypted_secrets` column to `workspaces`.

  Backs the `secrets` attribute on `Arbiter.Tasks.Workspace`, which is encrypted
  at rest via `ash_cloak` / `Arbiter.Vault` (AES-256-GCM). The column stores the
  Base64-wrapped ciphertext of the secrets map; it is never read in the clear by
  the data layer (decryption happens in the resource's `secrets` calculation).

  Nullable and additive — existing rows get `NULL` (treated as "no secrets"), so
  this is a zero-downtime, forward-only schema change with a clean rollback.
  """

  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :encrypted_secrets, :binary
    end
  end

  def down do
    alter table(:workspaces) do
      remove :encrypted_secrets
    end
  end
end
