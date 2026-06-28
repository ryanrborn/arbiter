defmodule Arbiter.Workflows.PRPatrolSupervisor do
  @moduledoc """
  DynamicSupervisor for PRPatrol processes — one per workspace configured for
  GitHub merges.

  Patrols are registered under `Arbiter.Workflows.PRPatrolRegistry` keyed by
  `workspace_id`, so duplicate starts collapse to `{:error, {:already_started,
  pid}}` and lookups via `whereis/1` are O(1).

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts a PRPatrol for each with a valid GitHub merge config.
  New workspaces start a patrol via the
  `Arbiter.Tasks.Workspace.Changes.StartPRPatrol` after_action hook.

  Both auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test`, enabled everywhere else.

  Poll interval is read from `:arbiter, :pr_patrol_interval_ms` (default 60s).
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Workflows.PRPatrol

  @registry Arbiter.Workflows.PRPatrolRegistry

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
  Start a PRPatrol for a workspace if its merge adapter implements `list_open/0`.
  Returns `:skip` when the adapter doesn't support listing open MRs, or when no
  repo string can be derived from workspace config (needed to dispatch follow-up
  workers). Idempotent: returns the existing pid via `{:error, {:already_started,
  pid}}` if one is already running for the workspace.
  """
  @spec start_patrol(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_patrol(%Workspace{} = workspace, opts \\ []) do
    adapter = resolve_adapter(workspace)

    with true <- not is_nil(adapter) and function_exported?(adapter, :list_open, 0),
         repo when is_binary(repo) <- patrol_repo(workspace) do
      child_opts =
        opts
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:workspace_id, workspace.id)
        |> Keyword.put_new(:interval_ms, patrol_interval_ms())
        |> Keyword.put(:name, via(workspace.id))

      DynamicSupervisor.start_child(__MODULE__, {PRPatrol, child_opts})
    else
      _ -> :skip
    end
  end

  @doc "Return the pid of the PRPatrol serving `workspace_id`, or `nil`."
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
  Whether patrols should auto-start. Shares the `:auto_start_refineries`
  config flag with `MergeQueueSupervisor` — false in test, true everywhere else.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end

  @doc """
  Enumerate every workspace and start a PRPatrol for those with a GitHub merge
  config. Best-effort: a failure for one workspace is logged but does not block
  the others. Called from the application supervision tree's boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_patrol(ws) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            :skip ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "PRPatrolSupervisor: failed to start patrol for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "PRPatrolSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("PRPatrolSupervisor: enumeration crashed at boot: #{Exception.message(e)}")

      :ok
  end

  # Resolve the merge adapter for a workspace, or nil on unknown strategy.
  defp resolve_adapter(workspace) do
    Mergers.for_workspace(workspace)
  rescue
    ArgumentError -> nil
  end

  # Derive a repo identifier string for follow-up worker dispatch. Returns nil
  # when the workspace config doesn't carry enough info to derive one.
  #
  # GitHub: "owner/repo" from merge config. Other adapters: extend here as their
  # patrol support lands.
  defp patrol_repo(%Workspace{} = workspace) do
    config = workspace.config || %{}

    case get_in(config, ["merge", "strategy"]) do
      "github" ->
        owner = get_in(config, ["merge", "config", "owner"])
        repo = get_in(config, ["merge", "config", "repo"])

        if is_binary(owner) and byte_size(owner) > 0 and
             is_binary(repo) and byte_size(repo) > 0 do
          "#{owner}/#{repo}"
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp patrol_interval_ms do
    Application.get_env(:arbiter, :pr_patrol_interval_ms, 60_000)
  end
end
