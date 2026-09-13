defmodule Arbiter.Accounts do
  @moduledoc """
  Ash domain for provider accounts (`docs/provider-account-design.md`).

  Phase P1 (bd-4qa1iw) only: the three resources exist so a migration can
  create their tables. **Nothing reads or writes them yet** — extraction from
  `worker_env` (P2), the read-path flip (P3), and everything after are later
  phases. `Arbiter.Accounts.Census` (P0) is a plain module, not a resource in
  this domain; it inspects `worker_env` read-only and emits a candidate plan
  for a future `mix arbiter.accounts.migrate`.
  """

  use Ash.Domain

  resources do
    resource Arbiter.Accounts.ProviderAccount
    resource Arbiter.Accounts.ProviderCredential
    resource Arbiter.Accounts.WorkspaceProviderAccount
  end
end
