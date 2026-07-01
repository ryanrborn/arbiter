defmodule Arbiter.Workflows.ReviewPatrolSupervisor do
  @moduledoc """
  DynamicSupervisor for `ReviewPatrol` processes — one per (workspace, repo)
  pair configured for GitHub merges. The reviewer-side counterpart of
  `PRPatrolSupervisor`, kept as a SEPARATE module and process registry
  (`Arbiter.Workflows.ReviewPatrolRegistry`) so the two patrols never share a
  registration namespace.

  Repo derivation, the single-repo vs multi-repo registry-key scheme, stale
  1↔N reconciliation, and boot/create-time auto-start all mirror
  `PRPatrolSupervisor` exactly — see that module for the full rationale. The
  only differences here are the process module (`ReviewPatrol`), the registry,
  and the poll-interval config key (`:review_patrol_interval_ms`).

  Both auto-start paths are gated by the same `:arbiter, :auto_start_refineries`
  flag PRPatrol uses — disabled in `test`, enabled everywhere else.
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.RepoConfig, Tasks.Workspace}
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Workflows.ReviewPatrol

  @registry Arbiter.Workflows.ReviewPatrolRegistry

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
  Start a ReviewPatrol for each repo configured in the workspace's GitHub merge
  config. Returns `:skip` when the adapter doesn't support `get/1` or when no
  repos can be derived from the workspace config.

  Single-repo workspaces start one patrol registered under `workspace_id`;
  multi-repo workspaces start one patrol per repo, registered under
  `"workspace_id:owner/repo"`. Idempotent: a duplicate start returns
  `{:error, {:already_started, pid}}`.
  """
  @spec start_patrol(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_patrol(%Workspace{} = workspace, opts \\ []) do
    adapter = resolve_adapter(workspace)
    repos = patrol_repos(workspace)

    cond do
      is_nil(adapter) or not function_exported?(adapter, :get, 1) ->
        Logger.info(
          "ReviewPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "merge adapter #{inspect(adapter)} does not support get/1"
        )

        :skip

      repos == [] ->
        Logger.info(
          "ReviewPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "no repos resolvable (set merge.config.repo, or a repo_paths/rig_paths " <>
            "map whose rigs have a github origin remote)"
        )

        :skip

      true ->
        reconcile_stale_registrations(workspace.id, repos)

        results =
          Enum.map(repos, fn repo ->
            registry_key =
              if length(repos) == 1, do: workspace.id, else: "#{workspace.id}:#{repo}"

            child_opts =
              opts
              |> Keyword.put(:repo, repo)
              |> Keyword.put(:workspace_id, workspace.id)
              |> Keyword.put_new(:interval_ms, patrol_interval_ms())
              |> Keyword.put(:name, via(registry_key))

            result = DynamicSupervisor.start_child(__MODULE__, {ReviewPatrol, child_opts})

            Logger.info(
              "ReviewPatrolSupervisor: patrol #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
            )

            result
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Return the pid of the ReviewPatrol registered under `workspace_id`, or `nil`.
  For multi-repo workspaces use `whereis_all/1`.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc """
  Return all `{registry_key, pid}` pairs for a workspace, covering both
  single-repo patrols (registered under `workspace_id`) and multi-repo patrols
  (registered under `"workspace_id:owner/repo"`).
  """
  @spec whereis_all(String.t()) :: [{String.t(), pid()}]
  def whereis_all(workspace_id) when is_binary(workspace_id) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _pid} ->
      key == workspace_id or String.starts_with?(key, workspace_id <> ":")
    end)
  end

  @doc false
  def via(workspace_id), do: {:via, Registry, {@registry, workspace_id}}

  @doc """
  Whether patrols should auto-start. Shares the `:auto_start_refineries` config
  flag with `PRPatrolSupervisor` / `MergeQueueSupervisor` — false in test, true
  everywhere else.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end

  @doc """
  Enumerate every workspace and start a ReviewPatrol for those with a GitHub
  merge config. Best-effort: a per-workspace failure is logged but does not
  block the others. Called from the application supervision tree's boot Task.
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
                "ReviewPatrolSupervisor: failed to start patrol for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrolSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "ReviewPatrolSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  # Stop any patrols registered under the opposite naming scheme for this
  # workspace before starting new ones, so a 1↔N transition in resolvable-repo
  # count doesn't leave a ghost patrol under the old registry key.
  defp reconcile_stale_registrations(workspace_id, repos) do
    if length(repos) == 1 do
      @registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.each(fn {key, pid} ->
        if String.starts_with?(key, workspace_id <> ":") do
          Logger.info(
            "ReviewPatrolSupervisor: stopping stale patrol #{key} (registry scheme changed to single-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)
        end
      end)
    else
      case Registry.lookup(@registry, workspace_id) do
        [{pid, _}] ->
          Logger.info(
            "ReviewPatrolSupervisor: stopping stale patrol #{workspace_id} (registry scheme changed to multi-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)

        _ ->
          :ok
      end
    end
  end

  # Resolve the merge adapter for a workspace, or nil on unknown strategy.
  # Load it before `start_patrol/2`'s `function_exported?/3` guard inspects it —
  # see bd-1hn1qw (mirrors PRPatrolSupervisor).
  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  # Derive the list of "owner/repo" strings to patrol for this workspace, exactly
  # as PRPatrolSupervisor does: single-repo (merge.config.repo set) or multi-repo
  # (one per rig, repo derived from each rig's origin remote).
  defp patrol_repos(%Workspace{} = workspace) do
    config = workspace.config || %{}

    case get_in(config, ["merge", "strategy"]) do
      "github" ->
        owner = get_in(config, ["merge", "config", "owner"])
        repo = get_in(config, ["merge", "config", "repo"])

        if is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
          ["#{owner}/#{repo}"]
        else
          repos_from_rig_paths(config)
        end

      _ ->
        []
    end
  end

  defp repos_from_rig_paths(config) do
    case Map.get(config, "repo_paths") || Map.get(config, "rig_paths") do
      rig_map when is_map(rig_map) ->
        rig_map
        |> Map.values()
        |> Enum.map(&RepoConfig.repo_path_from_config/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn path ->
          case RepoResolver.from_remote(path) do
            {:ok, {owner, repo}} ->
              ["#{owner}/#{repo}"]

            {:error, err} ->
              Logger.info(
                "ReviewPatrolSupervisor: could not derive repo for rig path #{path} " <>
                  "(skipping): #{inspect(err)}"
              )

              []
          end
        end)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp patrol_interval_ms do
    Application.get_env(:arbiter, :review_patrol_interval_ms, 60_000)
  end
end
