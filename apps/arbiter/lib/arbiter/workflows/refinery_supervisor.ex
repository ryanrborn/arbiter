defmodule Arbiter.Workflows.RefinerySupervisor do
  @moduledoc """
  DynamicSupervisor for merge queue (Refinery) processes — one per workspace.

  Refineries are registered under `Arbiter.Workflows.RefineryRegistry` keyed by
  `workspace_id`, so duplicate starts collapse to `{:error, {:already_started,
  pid}}` and lookups via `whereis/1` are O(1).

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts a Refinery for each — eager start means no missed
  `:polecat_done` events on a cold boot. New workspaces created at runtime
  start a Refinery via the `Arbiter.Beads.Workspace.Changes.StartRefinery`
  after_action hook.

  Both auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test` (so the refinery test can drive the
  GenServer with its own stubs and `auto_tick: false`), enabled everywhere
  else.

  Boot enumeration runs once, from the `Arbiter.Application` boot Task. If
  this supervisor crashes and the app supervisor restarts it, the new
  instance starts empty — workspaces stay refinery-less until either a new
  workspace is created (the `StartRefinery` after_action covers that) or the
  OS process restarts.
  """

  require Logger

  alias Arbiter.Beads.Workspace
  alias Arbiter.Workflows.Refinery

  @registry Arbiter.Workflows.RefineryRegistry

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
  Start a Refinery for a workspace_id. Idempotent: returns the existing pid
  via `{:error, {:already_started, pid}}` if one is already running for the
  workspace.
  """
  @spec start_refinery(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_refinery(workspace_id, opts \\ []) when is_binary(workspace_id) do
    # `:name` is always the via tuple — `Keyword.put` (not `put_new`) so a
    # caller cannot silently bypass the Registry-based idempotency.
    opts =
      opts
      |> Keyword.put(:workspace_id, workspace_id)
      |> Keyword.put(:name, via(workspace_id))

    DynamicSupervisor.start_child(__MODULE__, {Refinery, opts})
  end

  @doc "Return the pid of the Refinery serving `workspace_id`, or `nil`."
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
  Enumerate every workspace and start a Refinery for each. Best-effort: a
  failure to start one workspace's Refinery is logged but does not block the
  others. Called from the application supervision tree's boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_refinery(ws.id) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "RefinerySupervisor: failed to start refinery for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "RefinerySupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    # Ash.read/1 can raise (e.g. domain not yet registered, Repo refusing
    # connections, migration mid-flight at boot). Without this rescue the
    # boot Task crashes silently — surface the cause as a warning instead.
    e ->
      Logger.warning("RefinerySupervisor: enumeration crashed at boot: #{Exception.message(e)}")

      :ok
  end

  @doc """
  Whether the supervisor should auto-start refineries (boot enumeration +
  workspace-create hook). Disabled in test by default.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end
end
