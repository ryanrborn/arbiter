defmodule Arbiter.Quota.CodexQuota do
  @moduledoc """
  Per-workspace snapshot of Codex's (OpenAI) rate-limit / quota state (bd-cqfn5i).

  Unlike `Arbiter.Quota.AnthropicQuota`, which is populated *passively* from
  response headers the local proxy observes, this snapshot is populated
  *actively* by `Arbiter.Quota.Codex.fetch/2`, which makes one direct GET to
  OpenAI's usage endpoint using the `codex` CLI's stored OAuth token. See that
  module for the fetch/parse logic.

  Codex reports two windows:

    * `session` — the primary (short) window.
    * `weekly`  — the secondary (long) window.

  Each carries a used-percent (0–100) and a reset timestamp, mirroring the
  `{used, total: 100, remaining, resetAt}` shape 9router normalizes to.

  One row per `{workspace_id, provider}` — the `:upsert` action overwrites the
  prior snapshot in place, so this stays a cache of the latest reading, not a
  time series. Every window field is optional: a response carrying only the
  session window still writes a row with the weekly columns left `nil`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "codex_quotas"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      upsert? true
      upsert_identity :workspace_provider

      accept [
        :workspace_id,
        :provider,
        :plan,
        :session_used_percent,
        :session_reset_at,
        :weekly_used_percent,
        :weekly_reset_at,
        :limit_reached,
        :captured_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :workspace_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "Workspace these quota figures were captured for."
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      default "codex"
      constraints max_length: 64, trim?: true
    end

    attribute :plan, :string do
      public? true
      description "Codex plan tier reported by the usage endpoint (e.g. \"plus\")."
    end

    attribute :session_used_percent, :float, public?: true
    attribute :session_reset_at, :utc_datetime, public?: true

    attribute :weekly_used_percent, :float, public?: true
    attribute :weekly_reset_at, :utc_datetime, public?: true

    attribute :limit_reached, :boolean, public?: true

    attribute :captured_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When the direct usage call observed these figures."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One snapshot per workspace+provider; fetch/2 upserts onto this.
    identity :workspace_provider, [:workspace_id, :provider]
  end
end
