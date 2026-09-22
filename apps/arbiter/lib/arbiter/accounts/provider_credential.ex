defmodule Arbiter.Accounts.ProviderCredential do
  @moduledoc """
  Phase P1 (`docs/provider-account-design.md` §3.2). Append-only versions of a
  `ProviderAccount`'s secret material: rotation is an **insert**, never an
  update — that is what makes a late-discovered split recoverable (§2.5) and
  keeps every `usage_events` row's `provider_credential_id` meaningful across
  a rotation.

  Read by `Arbiter.Accounts.Credentials` since P3 (bd-aiodva), behind
  `Arbiter.Accounts.enabled?/0`. The secret is encrypted at rest with the
  same `Arbiter.Vault` cloak already used for
  `workspaces.encrypted_worker_env`.

  ## Append-only enforcement

  There is no `:update` action. The only actions are `:create` (§7.2's
  "rotation inserts a new credential row") and `:retire`, which flips `active`
  to `false` and stamps `retired_at` — it never touches `encrypted_secret`,
  `fingerprint`, `kind`, or `env_var`. A partial unique index enforces at most
  one active credential per `(provider_account_id, kind)`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  sqlite do
    table "provider_credentials"
    repo Arbiter.Repo

    references do
      reference :provider_account, on_delete: :delete
    end

    custom_indexes do
      # §3.2: "exactly one active per (account, provider, kind)". provider is
      # a property of the account (fixed for its lifetime), so the DB
      # constraint over (provider_account_id, kind) is equivalent and does
      # not need a redundant provider column on this table.
      index [:provider_account_id, :kind],
        unique: true,
        where: "active = true",
        name: "provider_credentials_unique_active_index"
    end
  end

  # Encrypts the `secret` attribute at rest. ash_cloak renames it to
  # `encrypted_secret` (binary column, public?: false) and replaces it with a
  # decrypting calculation of the same name — we don't enable
  # `decrypt_by_default` (see Workspace's cloak block for why) and instead
  # decrypt on demand via `secret/1`. The decrypted value is never serialised.
  cloak do
    vault(Arbiter.Vault)
    attributes([:secret])
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:provider_account_id, :kind, :env_var, :fingerprint, :scopes, :active, :secret]
    end

    update :retire do
      require_atomic? false
      accept []
      change set_attribute(:active, false)
      change set_attribute(:retired_at, &DateTime.utc_now/0)
    end

    # `arb account merge` (§2.5, P11): "provider_credentials rows move across
    # and stay distinct." Re-pointing the owning account is the one field a
    # merge legitimately changes; it never touches the append-only
    # secret/kind/fingerprint fields the moduledoc's append-only enforcement
    # is actually about.
    update :reassign_account do
      require_atomic? false
      accept [:provider_account_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:oauth_token, :api_key, :cli_credentials_file]

      description "The credential shape: oauth_token / api_key / cli_credentials_file."
    end

    attribute :env_var, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true

      description "The env var a worker receives it as, e.g. CLAUDE_CODE_OAUTH_TOKEN."
    end

    # ash_cloak-encrypted; see the `cloak` block above. Write-only via the
    # :create action's `secret` argument, never serialised.
    attribute :secret, :string do
      public? false
      allow_nil? false

      description "The credential material. Encrypted at rest; never read back in plaintext."
    end

    attribute :fingerprint, :string do
      allow_nil? false
      public? true
      constraints min_length: 1

      description "sha256 hex of the secret — dedup/rotation-detection evidence only, never an identity key (§2.4)."
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true

      description "§3.2's active? — exactly one true per (provider_account_id, kind)."
    end

    attribute :scopes, {:array, :string} do
      public? true
      allow_nil? true

      description "OAuth scopes recorded when known — explains why a credential cannot self-profile."
    end

    create_timestamp :created_at

    attribute :retired_at, :utc_datetime do
      public? true
      allow_nil? true

      description "Set by :retire when a newer credential supersedes this one. Rotation = insert active + mark predecessor retired."
    end
  end

  relationships do
    belongs_to :provider_account, Arbiter.Accounts.ProviderAccount do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  @doc """
  Decrypts and returns the credential's secret material.

  Reads the stored `encrypted_secret` column (always selected, since it is a
  plain attribute) and decrypts it with `Arbiter.Vault`. Mirrors
  `Arbiter.Tasks.Workspace.secrets_map/1`. The read path
  (`Arbiter.Accounts.Credentials`) decrypts through here on every spawn that
  runs with provider accounts enabled.
  """
  @spec secret(t()) :: String.t() | nil
  def secret(credential) do
    case Map.get(credential, :encrypted_secret) do
      enc when is_binary(enc) ->
        enc
        |> Base.decode64!()
        |> Arbiter.Vault.decrypt!()
        |> Ash.Helpers.non_executable_binary_to_term()

      _ ->
        nil
    end
  end
end
