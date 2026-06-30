defmodule Arbiter.Workflows.MergedPRFinalizerSupervisor do
  @moduledoc """
  DynamicSupervisor for MergedPRFinalizer processes — one per (workspace, repo)
  pair configured for GitHub merges. Mirrors `PRPatrolSupervisor` in structure.

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts a finalizer for those with a GitHub merge config. New
  workspaces start their finalizer via the
  `Arbiter.Tasks.Workspace.Changes.StartMergedPRFinalizer` after_action hook.

  Both auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test`, enabled everywhere else.

  Poll interval is read from `:arbiter, :merged_pr_finalizer_interval_ms`
  (default 120s — less frequent than PRPatrol's 60s since merged PRs are a
  lower-urgency recovery path).
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.RepoConfig, Tasks.Workspace}
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Workflows.MergedPRFinalizer

  @registry Arbiter.Workflows.MergedPRFinalizerRegistry

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
  Start a MergedPRFinalizer for each repo configured in the workspace's GitHub
  merge config. Returns `:skip` when the adapter doesn't support `get/1` or
  when no repos can be derived from the workspace config.

  Idempotent: a duplicate start returns `{:error, {:already_started, pid}}`.
  """
  @spec start_finalizer(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_finalizer(%Workspace{} = workspace, opts \\ []) do
    adapter = resolve_adapter(workspace)
    repos = finalizer_repos(workspace)

    cond do
      is_nil(adapter) or not function_exported?(adapter, :get, 1) ->
        Logger.info(
          "MergedPRFinalizerSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "merge adapter #{inspect(adapter)} does not support get/1"
        )

        :skip

      repos == [] ->
        Logger.info(
          "MergedPRFinalizerSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "no repos resolvable"
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
              |> Keyword.put_new(:interval_ms, finalizer_interval_ms())
              |> Keyword.put(:name, via(registry_key))

            result = DynamicSupervisor.start_child(__MODULE__, {MergedPRFinalizer, child_opts})

            Logger.info(
              "MergedPRFinalizerSupervisor: finalizer #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
            )

            result
          end)

        List.first(results, :skip)
    end
  end

  @doc "Return the pid registered under `workspace_id`, or `nil`."
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
  Whether finalizers should auto-start. Shares the `:auto_start_refineries`
  config flag — false in test, true everywhere else.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end

  @doc """
  Enumerate every workspace and start a MergedPRFinalizer for those with a
  GitHub merge config. Best-effort. Called from the application supervision
  tree's boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_finalizer(ws) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            :skip -> :ok
            {:error, reason} ->
              Logger.warning(
                "MergedPRFinalizerSupervisor: failed to start finalizer for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "MergedPRFinalizerSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizerSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  defp reconcile_stale_registrations(workspace_id, repos) do
    if length(repos) == 1 do
      @registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.each(fn {key, pid} ->
        if String.starts_with?(key, workspace_id <> ":") do
          Logger.info(
            "MergedPRFinalizerSupervisor: stopping stale finalizer #{key} (registry scheme changed to single-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)
        end
      end)
    else
      case Registry.lookup(@registry, workspace_id) do
        [{pid, _}] ->
          Logger.info(
            "MergedPRFinalizerSupervisor: stopping stale finalizer #{workspace_id} (registry scheme changed to multi-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)

        _ ->
          :ok
      end
    end
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  defp finalizer_repos(%Workspace{} = workspace) do
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
                "MergedPRFinalizerSupervisor: could not derive repo for rig path #{path} " <>
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

  defp finalizer_interval_ms do
    Application.get_env(:arbiter, :merged_pr_finalizer_interval_ms, 120_000)
  end
end
