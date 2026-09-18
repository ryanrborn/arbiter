defmodule Arbiter.Accounts do
  @moduledoc """
  Ash domain for provider accounts (`docs/provider-account-design.md`).

  Phases P1 (bd-4qa1iw) and P2 (bd-77j2if). P1 created the three tables; P2
  adds `Arbiter.Accounts.Migrate` — the plan-driven extraction that populates
  them out of each workspace's encrypted `worker_env` — and
  `Arbiter.Accounts.ProviderAccountMigrationBackup`, its undo record.

  **Nothing in the running system reads these tables yet.** P2 is §7.5's
  "Release N — additive": the rows exist, `workspaces.encrypted_worker_env`
  remains the source of truth for everything that spawns a worker, and
  `enabled?/0` answers `false`. The read-path flip
  (`Arbiter.Agents.Claude.ConfigDir`, `Arbiter.Worker.WorkerEnv`) is P3.

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

  §7.5's `:provider_accounts_enabled`. **Always `false` in this release** —
  it exists so P3's read flip has a switch to hang off, and so the flip is a
  config change rather than a deploy. Nothing consults it yet; flipping it
  today changes no behaviour whatsoever.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :provider_accounts_enabled, false) == true
end
