defmodule Arbiter.Repo.Migrations.AddCredentialWatchdogSettings do
  @moduledoc """
  Adds the `Arbiter.Agents.CredentialWatchdog` knobs to `installation_settings`
  (bd-ajgve2), so the probed-adapter list and the poll intervals can be changed
  at runtime instead of by editing `config/*.exs` and redeploying.

  All three columns are nullable and default to NULL, which means "fall back to
  the `:arbiter, :credential_watchdog` application env, else the Watchdog's
  hardcoded default" — so an install that never touches them keeps today's
  behavior exactly (probe every adapter in `Arbiter.Agents.adapters/0` every 5
  minutes, re-probing an expired adapter every minute).
  """

  use Ecto.Migration

  def up do
    alter table(:installation_settings) do
      add :credential_watchdog_adapters, {:array, :text}
      add :credential_watchdog_interval_ms, :integer
      add :credential_watchdog_recovery_interval_ms, :integer
    end
  end

  def down do
    alter table(:installation_settings) do
      remove :credential_watchdog_adapters
      remove :credential_watchdog_interval_ms
      remove :credential_watchdog_recovery_interval_ms
    end
  end
end
