defmodule Arbiter.Workflows.DispatchQueueSupervisor do
  @moduledoc """
  DynamicSupervisor for `Arbiter.Workflows.DispatchQueue` processes — one per
  workspace (bd-7cd38f), mirroring `Arbiter.Workflows.MergeQueueSupervisor`.

  Queues are registered under `Arbiter.Workflows.DispatchQueueRegistry` keyed by
  `workspace_id`, so duplicate starts collapse to `{:error, {:already_started,
  pid}}` and `whereis/1` is O(1).

  Unlike the MergeQueue, a dispatch queue is often first needed lazily — the
  moment the quota gate decides to HOLD a dispatch — so `ensure_started/1`
  start-or-returns the workspace's queue on demand. Boot enumeration
  (`start_for_existing_workspaces/0`) and the workspace-create hook still start
  them eagerly so the `quota:<ws>` subscription (drain-on-headroom) is live even
  before the first hold.

  Both eager paths are gated by `:arbiter, :auto_start_refineries` (off in test),
  the same flag the MergeQueue uses.
  """

  require Logger

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.DispatchQueue

  @registry Arbiter.Workflows.DispatchQueueRegistry

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
  Start a DispatchQueue for a workspace_id. Idempotent: returns the existing pid
  via `{:error, {:already_started, pid}}` if one is already running.
  """
  @spec start_dispatch_queue(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_dispatch_queue(workspace_id, opts \\ []) when is_binary(workspace_id) do
    opts =
      opts
      |> Keyword.put(:workspace_id, workspace_id)
      |> Keyword.put(:name, via(workspace_id))

    DynamicSupervisor.start_child(__MODULE__, {DispatchQueue, opts})
  end

  @doc """
  Return the workspace's DispatchQueue pid, starting one if none is running.

  This is the lazy path the dispatch quota seam uses: the first HOLD for a
  workspace spins up its queue. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(workspace_id) when is_binary(workspace_id) do
    case whereis(workspace_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      _ ->
        case start_dispatch_queue(workspace_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Return the pid of the DispatchQueue serving `workspace_id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc false
  def via(workspace_id), do: {:via, Registry, {@registry, workspace_id}}

  @doc """
  List every running dispatch queue as `[{workspace_id, pid}]`.
  """
  @spec list_queues() :: [{String.t(), pid()}]
  def list_queues do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Enumerate every workspace and start a DispatchQueue for each. Best-effort:
  a failure to start one workspace's queue is logged but does not block the
  others. Called from the application boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_dispatch_queue(ws.id) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "DispatchQueueSupervisor: failed to start dispatch queue for workspace " <>
                  "#{ws.id}: #{inspect(reason)}"
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "DispatchQueueSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "DispatchQueueSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Whether the supervisor should auto-start queues (boot enumeration +
  workspace-create hook). Shares the MergeQueue's `:auto_start_refineries` flag
  (disabled in test).
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end
end
