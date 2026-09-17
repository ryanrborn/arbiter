defmodule Arbiter.Settings.Installation do
  @moduledoc """
  Singleton row holding install-wide runtime settings that were previously
  only changeable by editing `config/*.exs` and redeploying (bd-2ogep0).

  Exactly one row is expected to exist at any time — enforced in
  `Arbiter.Settings` (get-or-create-singleton on first read/write), not at the
  DB layer, so future settings can be added here as plain nullable columns
  without a new singleton mechanism.

  ## Fields

    * `:conductor_system_max_concurrent` — install-wide Conductor concurrency
      ceiling (`Arbiter.Workflows.Conductor`). `nil` means "fall back to the
      `:arbiter, :conductor_system_max_concurrent` application env, else the
      hardcoded default".
    * `:credential_watchdog_adapters` — agent-type names
      (`Arbiter.Agents.valid_agent_types/0`) the
      `Arbiter.Agents.CredentialWatchdog` should probe. `nil` means "probe
      every adapter in `Arbiter.Agents.adapters/0`"; `[]` means "probe
      nothing".
    * `:credential_watchdog_interval_ms` / `:credential_watchdog_recovery_interval_ms`
      — Watchdog poll intervals. `nil` falls back to the
      `:arbiter, :credential_watchdog` application env, else the Watchdog's
      hardcoded defaults (5 minutes / 1 minute).
    * `:board_autopilot_paused` — `Arbiter.Board.Autopilot`'s pause flag.
      `nil` means "no persisted value — fall back to the
      `:arbiter, :board_autopilot, enabled:` application env, else paused".
    * `:board_autopilot_paused_at` / `:board_autopilot_paused_by` — when the
      flag was last changed and, where known, by what caller (an MCP tool, the
      REST API, the dashboard). `nil` until the first pause/resume.

  Every field is nullable and `nil` always means "no override" — a fresh
  install that never writes here behaves exactly as it did before the setting
  existed.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "installation_settings"
    repo Arbiter.Repo
  end

  @settable [
    :conductor_system_max_concurrent,
    :credential_watchdog_adapters,
    :credential_watchdog_interval_ms,
    :credential_watchdog_recovery_interval_ms,
    :board_autopilot_paused,
    :board_autopilot_paused_at,
    :board_autopilot_paused_by
  ]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @settable
    end

    update :update do
      primary? true
      require_atomic? false
      accept @settable
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :conductor_system_max_concurrent, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "Install-wide Conductor concurrency ceiling; nil falls back to app env / default."
    end

    attribute :credential_watchdog_adapters, {:array, :string} do
      public? true
      allow_nil? true

      description "Agent-type names the CredentialWatchdog probes; nil probes every adapter, [] probes none."
    end

    attribute :credential_watchdog_interval_ms, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "CredentialWatchdog normal poll interval (ms); nil falls back to app env / default."
    end

    attribute :credential_watchdog_recovery_interval_ms, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "CredentialWatchdog re-probe interval while an adapter is expired (ms); nil falls back to app env / default."
    end

    attribute :board_autopilot_paused, :boolean do
      public? true
      allow_nil? true

      description "Board Autopilot's persisted pause flag; nil falls back to app env / paused."
    end

    attribute :board_autopilot_paused_at, :utc_datetime_usec do
      public? true
      allow_nil? true

      description "When board_autopilot_paused was last changed."
    end

    attribute :board_autopilot_paused_by, :string do
      public? true
      allow_nil? true

      description "Who/what last changed board_autopilot_paused, where known (e.g. \"mcp\", \"api\", \"dashboard\")."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
