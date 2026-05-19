defmodule GtElixir.Polecat.Registry do
  @moduledoc """
  Thin wrapper exposing the `:via` tuple used to register `GtElixir.Polecat`
  GenServers by their bead_id.

  The underlying registry is started by `GtElixir.Application` under the name
  `#{__MODULE__}`. Callers should prefer `via_tuple/1` over hand-rolling
  `{:via, Registry, ...}` tuples.
  """

  @doc """
  Return the `:via` tuple a `GtElixir.Polecat` GenServer registers under for
  the given `bead_id`.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(bead_id) when is_binary(bead_id) do
    {:via, Registry, {__MODULE__, bead_id}}
  end

  @doc """
  Look up the pid of the polecat registered for `bead_id`, or `nil` if none.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(bead_id) when is_binary(bead_id) do
    case Registry.lookup(__MODULE__, bead_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
