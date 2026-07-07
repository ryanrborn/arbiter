defmodule Arbiter.Quota.GoogleQuota do
  @moduledoc """
  Per-workspace snapshot of a Google Cloud Code Assist provider's quota state —
  **Gemini CLI** (`provider: "gemini_cli"`) or **Antigravity**
  (`provider: "antigravity"`) — persisted for the web dashboard and history
  (bd-ajh7bd).

  Before this table, `Arbiter.Quota.CloudCode` fetched Google's quota live on
  every `/api/quota` call and threw the result away, so Gemini CLI / Antigravity
  could never appear on the topbar or `/usage` page (which only ever read the
  persisted quota tables). `Arbiter.Quota.CloudProbe` now refreshes these on a
  timer and upserts one row per `{workspace_id, provider}` here — mirroring
  `Arbiter.Quota.CodexQuota`.

  Google's API reports a *per-model* `remainingFraction` rather than time
  windows, so this row stores:

    * `snapshot` — the full serialized `CloudCode` snapshot (plan, per-model
      quota list, message) reconstructed verbatim for `arb quota` / the REST +
      MCP quota surface.
    * `used_percent` / `reset_at` — a single **representative** figure (the
      worst / most-used important model) so the topbar and `/usage` page — which
      render a utilization bar — have one number to draw without unpacking the
      per-model list.

  One row per `{workspace_id, provider}` — the `:upsert` action overwrites the
  prior snapshot in place, so this stays a cache of the latest reading.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "cloud_code_quotas"
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
        :message,
        :used_percent,
        :reset_at,
        :snapshot,
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
      constraints max_length: 64, trim?: true
      description "\"gemini_cli\" | \"antigravity\"."
    end

    attribute :plan, :string do
      public? true
      description "Plan / tier reported by loadCodeAssist (e.g. \"Free\", \"Pro\")."
    end

    attribute :message, :string do
      public? true

      description "Non-fatal status note (e.g. auth expired / project missing) when the fetch degraded."
    end

    attribute :used_percent, :float do
      public? true

      description "Representative used-percent (0-100): the worst / most-used important model, for the utilization bar."
    end

    attribute :reset_at, :utc_datetime do
      public? true
      description "Reset time of the representative model, when known."
    end

    attribute :snapshot, :map do
      public? true
      default %{}

      description "The full serialized CloudCode snapshot (plan, per-model quota list, message) for the CLI/REST/MCP surface."
    end

    attribute :captured_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When the direct Cloud Code Assist call observed these figures."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :workspace_provider, [:workspace_id, :provider]
  end
end
