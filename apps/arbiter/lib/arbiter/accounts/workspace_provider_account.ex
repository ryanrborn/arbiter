defmodule Arbiter.Accounts.WorkspaceProviderAccount do
  @moduledoc """
  Phase P1 (`docs/provider-account-design.md` §3.3). The workspace → account
  reference: a join row rather than per-provider FK columns on `workspaces`,
  because the provider set grows (Antigravity is recent) and this is the
  natural home for `share` (§4).

  **Nothing reads this resource yet** (P1 scope).

  Cardinality (§3.4): one account per provider per workspace, enforced by the
  `identity` below. A workspace may have `claude` on one account and `codex`
  on another (different `provider` rows). Multiple workspaces may point at the
  same account. Multiple accounts per provider for *one* workspace is a
  non-goal in v1 — that is the cardinality the unique index deliberately
  forecloses.

  ## Deviation from the design doc

  §3.3 lists `workspace_id` as `string`, but `Arbiter.Tasks.Workspace`'s
  primary key is `uuid_v7_primary_key :id` (a UUID, not a string) — see e.g.
  `Arbiter.Skills.Skill`'s `belongs_to :workspace`. `workspace_id` here is
  typed `:uuid` via `belongs_to` to match the actual schema.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Accounts,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "workspace_provider_accounts"
    repo Arbiter.Repo

    references do
      reference :workspace, on_delete: :delete
      reference :provider_account, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:workspace_id, :provider, :provider_account_id, :share]
    end

    update :update do
      primary? true
      require_atomic? false

      # workspace_id/provider are the identity; re-pointing to a different
      # account is the normal edit (rotation/merge), so provider_account_id
      # stays accepted.
      accept [:provider_account_id, :share]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:claude, :codex, :gemini_cli, :antigravity]
    end

    attribute :share, :integer do
      public? true
      allow_nil? true
      description "This workspace's cap on the account's concurrency ceiling (§4)."
    end
  end

  relationships do
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :provider_account, Arbiter.Accounts.ProviderAccount do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    # §3.4: one account per provider per workspace. The single hinge that
    # would have to be relaxed for multi-account load balancing (non-goal).
    identity :workspace_provider, [:workspace_id, :provider], eager_check?: true
  end
end
