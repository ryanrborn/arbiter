defmodule Arbiter.TerminateProbe do
  @moduledoc """
  A `GenServer` that reports its own `terminate/2` to a watcher process.

  Exists for bd-b6noq9 / #1930: `Arbiter.TestSandbox.teardown/2` has to stop a
  sandbox's owners in a way that runs `terminate/2`, because for
  `Arbiter.Worker` that callback is the only thing that reaps the agent's OS
  process and its descendants (bd-bmmj4w) — and a bare exit signal skips it on
  a process that does not trap exits.

  Like `Arbiter.Worker`, this probe does **not** trap exits, so it reports only
  when it is stopped through the `sys` terminate path. Killed with a signal, it
  dies silently and the watcher sees nothing.
  """

  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(watcher) when is_pid(watcher), do: GenServer.start_link(__MODULE__, watcher)

  @impl true
  def init(watcher), do: {:ok, watcher}

  @impl true
  def terminate(reason, watcher) do
    send(watcher, {:terminated, self(), reason})
    :ok
  end
end
