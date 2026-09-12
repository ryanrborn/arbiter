defmodule Arbiter.Quota.AnthropicQuota do
  @moduledoc """
  Per-workspace snapshot of Anthropic's unified rate-limit / quota state.

  Anthropic returns `anthropic-ratelimit-unified-*` headers on *every*
  `/v1/messages` response (success or failure). `Arbiter.Quota.capture/3`
  upserts one row per workspace+provider here, so the fleet can read current
  utilization without making an extra API call.

  One row per `{workspace_id, provider}` — the `:upsert` action overwrites the
  prior snapshot in place, so this table stays tiny (it is a cache of the
  latest reading, not a time series).

  Every field except `workspace_id` is optional: a response that carries only
  the 5h window still writes a row, with the 7d columns left `nil`.

  ## Two write paths (bd-b0zody)

  The header capture above (`:upsert`) is no longer the only source of the
  primary columns: `Arbiter.Quota.capture_oauth_usage/2` polls Anthropic's
  `/api/oauth/usage` and writes the same columns through
  `:record_oauth_snapshot`, so the dispatch gate keeps working for a fleet
  that is making no proxied traffic at all. Both paths stamp
  `capture_source` so a row says which one last wrote it.
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
        :captured_at,
        :capture_source
      ]
    end

    # Secondary-only oauth write (bd-8tpha6): per-model weekly utilization +
    # `extra_usage`. Used when the polled body carried no aggregate 5h figure
    # to gate on — its narrow `upsert_fields` deliberately excludes
    # `captured_at` / `capture_source`, so layering per-model data onto a row
    # the proxy filled in never re-dates that row or claims its provenance.
    create :record_oauth_usage do
      upsert? true
      upsert_identity :workspace_provider

      upsert_fields [
        :per_model_utilization,
        :extra_usage,
        :oauth_utilization_5h,
        :oauth_utilization_7d,
        :oauth_captured_at
      ]

      accept [
        :workspace_id,
        :provider,
        :per_model_utilization,
        :extra_usage,
        :oauth_utilization_5h,
        :oauth_utilization_7d,
        :oauth_captured_at
      ]
    end

    # The polled `/api/oauth/usage` write path (bd-b0zody). Originally a
    # *secondary* layer only (per-model weekly + `extra_usage`, bd-8tpha6);
    # it now also carries the primary gate columns, so the dispatch gate no
    # longer depends on a worker having recently gone through the proxy.
    #
    # `upsert_fields` lists every column either layer can write, but
    # `AshSqlite` narrows that to the attributes actually present on the
    # changeset — so `Arbiter.Quota.record_oauth_snapshot/3` drops the keys
    # the parsed body had nothing for, and a partial body never nils out a
    # column the header capture had filled in.
    create :record_oauth_snapshot do
      upsert? true
      upsert_identity :workspace_provider

      upsert_fields [
        :per_model_utilization,
        :extra_usage,
        :oauth_utilization_5h,
        :oauth_utilization_7d,
        :oauth_captured_at,
        :utilization_5h,
        :reset_5h_at,
        :status_5h,
        :utilization_7d,
        :reset_7d_at,
        :status_7d,
        :representative_claim,
        :overage_status,
        :captured_at,
        :capture_source
      ]

      accept [
        :workspace_id,
        :provider,
        :per_model_utilization,
        :extra_usage,
        :oauth_utilization_5h,
        :oauth_utilization_7d,
        :oauth_captured_at,
        :utilization_5h,
        :reset_5h_at,
        :status_5h,
        :utilization_7d,
        :reset_7d_at,
        :status_7d,
        :representative_claim,
        :overage_status,
        :captured_at,
        :capture_source
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
      description ~s(Which window currently binds: "five_hour" | "seven_day".)
    end

    attribute :overage_status, :string, public?: true

    attribute :captured_at, :utc_datetime do
      allow_nil? false
      public? true
      # Both write paths accept this, but `:record_oauth_snapshot` only sets
      # it when the polled body actually carried primary-window figures — an
      # oauth write that layered on per-model data alone must not advertise
      # the row as freshly gated. The default keeps the not-null constraint
      # satisfiable on such an insert.
      default &DateTime.utc_now/0
      description "When the figures in the primary columns were observed."
    end

    attribute :capture_source, :string do
      public? true
      constraints max_length: 32, trim?: true

      description ~s(Which source last wrote the primary columns: "headers" = proxy capture, "oauth_poll" = /api/oauth/usage poll. nil on legacy rows.)
    end

    attribute :per_model_utilization, :map do
      public? true
      default %{}

      description "Per-model 7d utilization fraction (0-1) from /api/oauth/usage, e.g. %{\"sonnet\" => 0.42}."
    end

    attribute :extra_usage, :map do
      public? true
      default %{}

      description "Overage spend beyond the plan's included quota, as returned by /api/oauth/usage."
    end

    attribute :oauth_utilization_5h, :float do
      public? true

      description "5h utilization fraction from /api/oauth/usage — a cross-check against utilization_5h."
    end

    attribute :oauth_utilization_7d, :float do
      public? true

      description "7d utilization fraction from /api/oauth/usage — a cross-check against utilization_7d."
    end

    attribute :oauth_captured_at, :utc_datetime do
      public? true
      description "When /api/oauth/usage was last successfully fetched."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One snapshot per workspace+provider; the proxy upserts onto this.
    identity :workspace_provider, [:workspace_id, :provider]
  end
end
