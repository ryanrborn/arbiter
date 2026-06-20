defmodule Arbiter.Worker.Registry do
  @moduledoc """
  Thin wrapper exposing the `:via` tuple used to register `Arbiter.Worker`
  GenServers by their task_id.

  The underlying registry is started by `Arbiter.Application` under the name
  `#{__MODULE__}`. Callers should prefer `via_tuple/1` over hand-rolling
  `{:via, Registry, ...}` tuples.
  """

  @doc """
  Return the `:via` tuple a `Arbiter.Worker` GenServer registers under for
  the given `task_id`.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(task_id) when is_binary(task_id) do
    {:via, Registry, {__MODULE__, task_id}}
  end

  @doc """
  Look up the pid of the worker registered for `task_id`, or `nil` if none.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(task_id) when is_binary(task_id) do
    case Registry.lookup(__MODULE__, task_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Explicitly remove this process's registration. Called from the worker's
  `terminate/2` callback so callers observe `whereis/1 == nil` synchronously
  after `GenServer.stop/1` returns, rather than waiting on Registry's async
  monitor cleanup.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(task_id) when is_binary(task_id) do
    Registry.unregister(__MODULE__, task_id)
    :ok
  end
end
