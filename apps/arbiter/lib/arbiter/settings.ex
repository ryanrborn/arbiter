defmodule Arbiter.Settings do
  @moduledoc """
  Ash domain + public API for install-wide runtime settings (bd-2ogep0).

  Backs a small persisted singleton (`Arbiter.Settings.Installation`) so
  settings that used to require editing `config/*.exs` and redeploying — e.g.
  the Conductor's system-wide `max_concurrent` ceiling
  (`Arbiter.Workflows.Conductor`), or which adapters
  `Arbiter.Agents.CredentialWatchdog` probes — can be read and changed at
  runtime, taking effect on the next drain / poll cycle with no restart.

  Every setting is nullable and `nil` means "no override" — the caller falls
  back to the application env / its own hardcoded default, so an install that
  never writes here behaves exactly as it did before the setting existed.

  Reads are resilient: any DB error (including "table doesn't exist yet" on a
  not-yet-migrated install) is swallowed and treated as "no override set",
  falling back to the caller's own default. Writes surface errors normally —
  a failed write should be visible to whoever asked for the change.
  """

  use Ash.Domain

  alias Arbiter.Settings.Installation

  resources do
    resource Installation
  end

  @doc """
  The install-wide Conductor concurrency ceiling override, or `nil` if unset
  (caller should fall back to app env / hardcoded default). Never raises —
  any read failure is treated as "unset".
  """
  @spec conductor_system_max_concurrent() :: pos_integer() | nil
  def conductor_system_max_concurrent, do: read_setting(:conductor_system_max_concurrent)

  @doc """
  Set the install-wide Conductor concurrency ceiling. `nil` clears the
  override (falls back to app env / hardcoded default). Returns the updated
  value (or `nil` when cleared).
  """
  @spec set_conductor_system_max_concurrent(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_conductor_system_max_concurrent(n) when is_nil(n) or (is_integer(n) and n > 0),
    do: write_setting(:conductor_system_max_concurrent, n)

  def set_conductor_system_max_concurrent(_), do: {:error, :invalid_value}

  @doc """
  The adapter names `Arbiter.Agents.CredentialWatchdog` should probe, or `nil`
  if unset (the Watchdog then probes every adapter in
  `Arbiter.Agents.adapters/0`). An empty list is a real value meaning "probe
  nothing". Never raises — any read failure is treated as "unset".
  """
  @spec credential_watchdog_adapters() :: [String.t()] | nil
  def credential_watchdog_adapters, do: read_setting(:credential_watchdog_adapters)

  @doc """
  Set the adapter names the Watchdog probes. Each entry must be one of
  `Arbiter.Agents.valid_agent_types/0`. `nil` clears the override (probe every
  adapter); `[]` disables probing entirely. Takes effect on the Watchdog's next
  poll cycle — no restart.
  """
  @spec set_credential_watchdog_adapters([String.t()] | nil) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def set_credential_watchdog_adapters(nil), do: write_setting(:credential_watchdog_adapters, nil)

  def set_credential_watchdog_adapters(names) when is_list(names) do
    valid = Arbiter.Agents.valid_agent_types()

    if Enum.all?(names, &(is_binary(&1) and &1 in valid)) do
      write_setting(:credential_watchdog_adapters, names)
    else
      {:error, :invalid_value}
    end
  end

  def set_credential_watchdog_adapters(_), do: {:error, :invalid_value}

  @doc """
  The Watchdog's normal poll interval in ms, or `nil` if unset (caller falls
  back to app env / hardcoded default). Never raises.
  """
  @spec credential_watchdog_interval_ms() :: pos_integer() | nil
  def credential_watchdog_interval_ms, do: read_setting(:credential_watchdog_interval_ms)

  @doc """
  Set the Watchdog's normal poll interval in ms. `nil` clears the override.
  Takes effect on the poll cycle after the currently-armed timer fires — no
  restart.
  """
  @spec set_credential_watchdog_interval_ms(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_credential_watchdog_interval_ms(ms) when is_nil(ms) or (is_integer(ms) and ms > 0),
    do: write_setting(:credential_watchdog_interval_ms, ms)

  def set_credential_watchdog_interval_ms(_), do: {:error, :invalid_value}

  @doc """
  The Watchdog's re-probe interval (ms) while an adapter is known-expired, or
  `nil` if unset. Never raises.
  """
  @spec credential_watchdog_recovery_interval_ms() :: pos_integer() | nil
  def credential_watchdog_recovery_interval_ms,
    do: read_setting(:credential_watchdog_recovery_interval_ms)

  @doc """
  Set the Watchdog's expired-adapter re-probe interval in ms. `nil` clears the
  override.
  """
  @spec set_credential_watchdog_recovery_interval_ms(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_credential_watchdog_recovery_interval_ms(ms)
      when is_nil(ms) or (is_integer(ms) and ms > 0),
      do: write_setting(:credential_watchdog_recovery_interval_ms, ms)

  def set_credential_watchdog_recovery_interval_ms(_), do: {:error, :invalid_value}

  # ---- singleton plumbing --------------------------------------------------

  # Reads never raise: a missing table (not-yet-migrated install) or any other
  # DB error is treated as "no override set".
  defp read_setting(field) do
    case singleton() do
      %Installation{} = row -> Map.fetch!(row, field)
      nil -> nil
    end
  rescue
    _ -> nil
  end

  # Writes surface errors normally — a failed write should be visible to
  # whoever asked for the change.
  defp write_setting(field, value) do
    with {:ok, row} <- get_or_create_singleton(),
         {:ok, updated} <- Ash.update(row, %{field => value}, action: :update) do
      {:ok, Map.fetch!(updated, field)}
    end
  end

  defp singleton do
    case Ash.read(Installation) do
      {:ok, [row | _]} -> row
      _ -> nil
    end
  end

  defp get_or_create_singleton do
    case Ash.read(Installation) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> Ash.create(Installation, %{})
      {:error, reason} -> {:error, reason}
    end
  end
end
