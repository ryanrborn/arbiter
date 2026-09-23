defmodule Arbiter.Accounts.ProviderAccount do
  @moduledoc """
  Phase P1 (`docs/provider-account-design.md` §3.1). The account row **is**
  the identity (§2.4): `id` is a locally-minted UUID, never derived from a
  credential. The operator names it (`slug`); credentials, quota, and
  concurrency hang off `id` and survive rotation because none of them ever
  point at the credential itself.

  **Nothing reads this resource yet.** It exists so the migration can create
  `provider_accounts`. Extraction (P2), the read-path flip (P3), quota re-key
  (P5) and `arb account` (P11) are later phases.

  ## Deviations from the design doc

  * `provider` uses the `gemini_cli` spelling (not `gemini`, as literally
    written in §3.1) to match `Arbiter.Quota.provider_code/1` and the
    already-merged `Arbiter.Accounts.Census` (P0), which both settled on
    `gemini_cli` as the canonical code.
  * `enabled?` / `active?`-style trailing-`?` attribute names are not used
    elsewhere in this codebase's Ash resources (e.g. `Skill.code_only`,
    `CodexQuota.limit_reached`), so `enabled` (§3.1's `enabled?`) is named
    without the `?` here for consistency.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Accounts,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "provider_accounts"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :provider,
        :slug,
        :label,
        :plan,
        :provider_account_ref,
        :provider_org_ref,
        :identity_source,
        :identity_verified_at,
        :max_concurrent,
        :quota_config,
        :enabled,
        :merged_into_id
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      # `provider` and `slug` together are the identity (§3.1) and are
      # deliberately not accepted here — changing either is a new account,
      # not an edit of this one.
      accept [
        :label,
        :plan,
        :provider_account_ref,
        :provider_org_ref,
        :identity_source,
        :identity_verified_at,
        :max_concurrent,
        :quota_config,
        :enabled,
        :merged_into_id
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:claude, :codex, :gemini_cli, :antigravity]

      description "Arbiter.Quota.provider_code/1 code this account is metered under."
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true

      description "Operator handle, unique per provider — arb quota --account <slug>."
    end

    attribute :label, :string do
      public? true
      description "Display name."
    end

    attribute :plan, :string do
      public? true
      allow_nil? true
      description "max_5x / max_20x / pro / team — operator-stated or profile-derived."
    end

    attribute :provider_account_ref, :string do
      public? true
      allow_nil? true
      description "account.uuid when obtainable (§2.4) — verification only, never a key."
    end

    attribute :provider_org_ref, :string do
      public? true
      allow_nil? true
      description "organization.uuid when obtainable."
    end

    attribute :identity_source, :atom do
      allow_nil? false
      public? true
      default :operator
      constraints one_of: [:operator, :provider_profile]

      description "How this account's identity was established."
    end

    attribute :identity_verified_at, :utc_datetime do
      public? true
      allow_nil? true
      description "When the provider profile last corroborated this account's identity."
    end

    attribute :max_concurrent, :integer do
      public? true
      allow_nil? true
      description "Account concurrency ceiling (§4). nil = no ceiling (migration default)."
    end

    attribute :quota_config, :map do
      public? true
      default %{}

      description "Account-scoped gate settings: throttle_threshold, weekly_threshold, weekly_warning_policy, threshold_mode (flat | paced), paced_floor, weekly_paced_floor, window_seconds (window label => seconds), overage opt-in."
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
      description "An account can be parked (false) without deleting it. §3.1's enabled?."
    end

    attribute :merged_into_id, :uuid do
      public? true
      allow_nil? true

      description "Set by arb account merge (§2.5, P11) — the surviving account this one merged into."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :provider_slug, [:provider, :slug], eager_check?: true
  end
end
