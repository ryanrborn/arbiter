defmodule Arbiter.Accounts do
  @moduledoc """
  Ash domain for provider accounts (`docs/provider-account-design.md`).

  Phases P1 (bd-4qa1iw), P2 (bd-77j2if) and P3 (bd-aiodva). P1 created the
  three tables; P2 added `Arbiter.Accounts.Migrate` — the plan-driven
  extraction that populates them out of each workspace's encrypted
  `worker_env` — and `Arbiter.Accounts.ProviderAccountMigrationBackup`, its
  undo record.

  P3 is §7.5's "Release N+1 — read flip": `Arbiter.Accounts.Credentials`
  reads these tables, and `Arbiter.Agents.Claude.ConfigDir` /
  `Arbiter.Worker.WorkerEnv` source provider credentials from it **when
  `enabled?/0` is true**. The flag still ships `false`, so by default nothing
  consults them and `workspaces.encrypted_worker_env` remains the source of
  truth for every spawn. The blob is untouched either way — flipping the flag
  back is the whole of the rollback. Deleting the old fallbacks is P4
  (bd-cblemv).

  `Arbiter.Accounts.Census` (P0) is a plain module, not a resource in this
  domain; it inspects `worker_env` read-only and emits the candidate plan
  `Arbiter.Accounts.Migrate` consumes.
  """

  use Ash.Domain

  resources do
    resource Arbiter.Accounts.ProviderAccount
    resource Arbiter.Accounts.ProviderCredential
    resource Arbiter.Accounts.ProviderAccountMigrationBackup
    resource Arbiter.Accounts.WorkspaceProviderAccount
  end

  @doc """
  Whether the provider-account tables are the source of truth for credentials.

  §7.5's `:provider_accounts_enabled`. Ships `false`; flipping it is a config
  change rather than a deploy, in either direction.

  Consulted by `Arbiter.Agents.Claude.ConfigDir.oauth_token/1` (and therefore
  `env/1`) and `Arbiter.Worker.WorkerEnv.resolve/1` — P3's read flip. With it
  on, a workspace that still carries a provider credential in its
  `worker_env` but has no `workspace_provider_accounts` row raises
  `Arbiter.Accounts.MissingCredentialError` rather than dispatching a worker
  with no credential: run `mix arbiter.accounts.migrate` for that workspace
  first, or turn the flag back off.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :provider_accounts_enabled, false) == true
end
