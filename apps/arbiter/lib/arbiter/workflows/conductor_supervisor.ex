defmodule Arbiter.Workflows.ConductorSupervisor do
  @moduledoc """
  DynamicSupervisor for `Arbiter.Workflows.Conductor` processes — one per
  **running** Graph.

  Conductors are registered under `Arbiter.Workflows.ConductorRegistry` keyed by
  `graph_id`, so a duplicate start collapses to `{:error, {:already_started,
  pid}}` and lookups via `whereis/1` are O(1).

  Unlike `MergeQueueSupervisor`, there is **no boot enumeration** here: a graph
  only gets a Conductor when something explicitly kicks it off
  (`Conductor.kickoff/2`), which is what flips it `draft → running`. Crash
  recovery — re-spawning a Conductor for a graph already in `:running` after a
  node restart — is deliberately out of scope for C3 and lands with crash-safety
  (C6). If this supervisor restarts, it comes back empty and running graphs stay
  conductor-less until kicked off again.

  Child specs use `restart: :temporary` (matching `Watchdog`/`ReviewGate`): a
  Conductor that exits — normally on `:drained`, or abnormally on a crash — is
  not auto-restarted. The durable-restart story is C6.
  """

  alias Arbiter.Workflows.Conductor

  @registry Arbiter.Workflows.ConductorRegistry

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start:
        {DynamicSupervisor, :start_link,
         [Keyword.merge([name: __MODULE__, strategy: :one_for_one], opts)]},
      type: :supervisor
    }
  end

  @doc """
  Start a Conductor for `graph_id`. Idempotent: returns the existing pid via
  `{:error, {:already_started, pid}}` if one is already running for the graph.

  `:name` is always forced to the via tuple so a caller cannot bypass the
  Registry-based idempotency. Remaining `opts` are passed through to
  `Conductor.start_link/1` (e.g. `:max_concurrent`, `:dispatcher`).
  """
  @spec start_conductor(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_conductor(graph_id, opts \\ []) when is_binary(graph_id) do
    opts =
      opts
      |> Keyword.put(:graph_id, graph_id)
      |> Keyword.put(:name, via(graph_id))

    DynamicSupervisor.start_child(__MODULE__, {Conductor, opts})
  end

  @doc "Return the pid of the Conductor driving `graph_id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(graph_id) when is_binary(graph_id) do
    case Registry.lookup(@registry, graph_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc """
  List every running conductor as `[{graph_id, pid}]`, read from the Registry.
  Best-effort: returns `[]` if the Registry isn't available.
  """
  @spec list_conductors() :: [{String.t(), pid()}]
  def list_conductors do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Stop the Conductor driving `graph_id`, if one is running. Returns `:ok`
  whether or not a process was found.
  """
  @spec stop_conductor(String.t()) :: :ok
  def stop_conductor(graph_id) when is_binary(graph_id) do
    case whereis(graph_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  def via(graph_id), do: {:via, Registry, {@registry, graph_id}}
end
