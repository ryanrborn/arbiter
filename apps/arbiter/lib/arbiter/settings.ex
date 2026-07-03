defmodule Arbiter.Settings do
  @moduledoc """
  Ash domain + public API for install-wide runtime settings (bd-2ogep0).

  Backs a small persisted singleton (`Arbiter.Settings.Installation`) so
  settings that used to require editing `config/*.exs` and redeploying — e.g.
  the Conductor's system-wide `max_concurrent` ceiling
  (`Arbiter.Workflows.Conductor`) — can be read and changed at runtime, taking
  effect on the next drain cycle with no restart.

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
  def conductor_system_max_concurrent do
    case singleton() do
      %Installation{conductor_system_max_concurrent: n} -> n
      nil -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Set the install-wide Conductor concurrency ceiling. `nil` clears the
  override (falls back to app env / hardcoded default). Returns the updated
  value (or `nil` when cleared).
  """
  @spec set_conductor_system_max_concurrent(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_conductor_system_max_concurrent(n) when is_nil(n) or (is_integer(n) and n > 0) do
    with {:ok, row} <- get_or_create_singleton(),
         {:ok, updated} <-
           Ash.update(row, %{conductor_system_max_concurrent: n}, action: :update) do
      {:ok, updated.conductor_system_max_concurrent}
    end
  end

  def set_conductor_system_max_concurrent(_), do: {:error, :invalid_value}

  # ---- singleton plumbing --------------------------------------------------

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
