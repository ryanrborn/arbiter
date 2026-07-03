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
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "installation_settings"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:conductor_system_max_concurrent]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:conductor_system_max_concurrent]
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

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
