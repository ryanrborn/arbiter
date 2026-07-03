defmodule Arbiter.Repo.Migrations.CreateInstallationSettings do
  @moduledoc """
  Creates `installation_settings` (bd-2ogep0): a singleton table holding
  install-wide runtime settings that were previously only changeable by
  editing `config/*.exs` and redeploying.

  Starts with a single nullable column, `conductor_system_max_concurrent` —
  the install-wide Conductor concurrency ceiling
  (`Arbiter.Workflows.Conductor`). `nil` means "fall back to the
  `:conductor_system_max_concurrent` application env / hardcoded default".

  Exactly one row is expected to ever exist; enforced in
  `Arbiter.Settings.Installation` (get-or-create-singleton), not at the DB
  layer, so future settings can be added as plain columns without a new
  migration pattern.
  """

  use Ecto.Migration

  def up do
    create table(:installation_settings, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :conductor_system_max_concurrent, :integer

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop_if_exists table(:installation_settings)
  end
end
