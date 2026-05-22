defmodule Arbiter.Workflows.MachineRegistry do
  @moduledoc """
  Thin wrapper around the `Registry` named `Arbiter.Workflows.MachineRegistry`,
  used to key running `Arbiter.Workflows.Machine` processes by their
  MachineState id (a UUID v7 string).

  The Registry itself is started by `Arbiter.Application`.
  """

  @registry __MODULE__

  @doc "Build a `:via` tuple suitable for `name:` in `GenStateMachine.start_link/3`."
  def via_tuple(id) when is_binary(id), do: {:via, Registry, {@registry, id}}

  @doc "Return the pid registered for `id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Best-effort unregister. Used by `Machine.terminate/3`."
  def unregister(id) when is_binary(id) do
    Registry.unregister(@registry, id)
    :ok
  end
end
