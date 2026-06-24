defmodule Arbiter.Quota.AnthropicQuota do
  @moduledoc """
  Per-workspace snapshot of Anthropic's unified rate-limit / quota state.

  Anthropic returns `anthropic-ratelimit-unified-*` headers on *every*
  `/v1/messages` response (success or failure). The local HTTP proxy
  (`ArbiterWeb.AnthropicProxyController`) captures them and upserts one row
  per workspace+provider here, so the fleet can read current utilization
  without making an extra API call.

  One row per `{workspace_id, provider}` — the `:upsert` action overwrites the
  prior snapshot in place, so this table stays tiny (it is a cache of the
  latest reading, not a time series).

  Every field except `workspace_id` is optional: a response that carries only
  the 5h window still writes a row, with the 7d columns left `nil`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "anthropic_quotas"
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
        :utilization_5h,
        :reset_5h_at,
        :status_5h,
        :utilization_7d,
        :reset_7d_at,
        :status_7d,
        :representative_claim,
        :overage_status,
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
      default "claude"
      constraints max_length: 64, trim?: true
    end

    attribute :utilization_5h, :float, public?: true
    attribute :reset_5h_at, :utc_datetime, public?: true
    attribute :status_5h, :string, public?: true

    attribute :utilization_7d, :float, public?: true
    attribute :reset_7d_at, :utc_datetime, public?: true
    attribute :status_7d, :string, public?: true

    attribute :representative_claim, :string do
      public? true
      description "Which window currently binds: \"five_hour\" | \"seven_day\"."
    end

    attribute :overage_status, :string, public?: true

    attribute :captured_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When the proxy observed these headers."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One snapshot per workspace+provider; the proxy upserts onto this.
    identity :workspace_provider, [:workspace_id, :provider]
  end
end
