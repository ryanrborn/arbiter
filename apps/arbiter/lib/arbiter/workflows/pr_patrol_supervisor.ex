defmodule Arbiter.Workflows.PRPatrolSupervisor do
  @moduledoc """
  DynamicSupervisor for PRPatrol processes — one per (workspace, repo) pair
  configured for GitHub merges.

  Single-repo workspaces (those with `config["merge"]["config"]["repo"]` set)
  get exactly one PRPatrol, registered under their `workspace_id`.

  Multi-repo workspaces (those with `config["merge"]["config"]["repos"]` — a
  list of repo names, all sharing the same `owner`) get one PRPatrol per repo,
  registered under `"workspace_id:owner/repo"`. This covers the leotech
  workspace shape, where each of the four `leo-technologies-llc/*` repos must
  be patrolled independently.

  Patrols are registered under `Arbiter.Workflows.PRPatrolRegistry`. Duplicate
  starts collapse to `{:error, {:already_started, pid}}`.

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts patrols for those with a GitHub merge config. New
  workspaces start their patrol(s) via the
  `Arbiter.Tasks.Workspace.Changes.StartPRPatrol` after_action hook.

  Both auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test`, enabled everywhere else.

  Poll interval is read from `:arbiter, :pr_patrol_interval_ms` (default 60s).

  ## Observable signals

  A `Logger.info` line is emitted for every patrol started or skipped, so
  operators can confirm which workspaces are covered without querying the
  `PRPatrolRegistry` directly.
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
  Start a PRPatrol for each repo configured in the workspace's GitHub merge
  config. Returns `:skip` when the adapter doesn't support `list_open/0` or
  when no repos can be derived from the workspace config.

  Single-repo workspaces (`config["merge"]["config"]["repo"]` is set) start
  one patrol registered under `workspace_id`. Multi-repo workspaces
  (`config["merge"]["config"]["repos"]` is a list) start one patrol per repo,
  each registered under `"workspace_id:owner/repo"`.

  Idempotent: a duplicate start for an already-running patrol returns
  `{:error, {:already_started, pid}}`.

  Emits a `Logger.info` line for each patrol started (or skipped), providing
  an observable signal that the boot wiring is working without needing to query
  the `PRPatrolRegistry` directly.
  """
  @spec start_patrol(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_patrol(%Workspace{} = workspace, opts \\ []) do
    adapter = resolve_adapter(workspace)
    repos = patrol_repos(workspace)

    cond do
      is_nil(adapter) or not function_exported?(adapter, :list_open, 0) ->
        Logger.info(
          "PRPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "merge adapter #{inspect(adapter)} does not support list_open/0"
        )

        :skip

      repos == [] ->
        Logger.info(
          "PRPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "no repos in merge config (set merge.config.repo or merge.config.repos)"
        )

        :skip

      true ->
        results =
          Enum.map(repos, fn repo ->
            registry_key = if length(repos) == 1, do: workspace.id, else: "#{workspace.id}:#{repo}"

            child_opts =
              opts
              |> Keyword.put(:repo, repo)
              |> Keyword.put(:workspace_id, workspace.id)
              |> Keyword.put_new(:interval_ms, patrol_interval_ms())
              |> Keyword.put(:name, via(registry_key))

            result = DynamicSupervisor.start_child(__MODULE__, {PRPatrol, child_opts})

            Logger.info(
              "PRPatrolSupervisor: patrol #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
            )

            result
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Return the pid of the PRPatrol registered under `workspace_id`, or `nil`.

  Works for single-repo workspaces (registered under their `workspace_id`).
  For multi-repo workspaces, each patrol is registered under
  `"workspace_id:owner/repo"` — use `Registry.select/2` on
  `Arbiter.Workflows.PRPatrolRegistry` to enumerate all patrols for a workspace.
  """
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
      Logger.warning(
        "PRPatrolSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  # Resolve the merge adapter for a workspace, or nil on unknown strategy.
  defp resolve_adapter(workspace) do
    Mergers.for_workspace(workspace)
  rescue
    ArgumentError -> nil
  end

  # Derive the list of "owner/repo" strings to patrol for this workspace.
  # Returns an empty list when no repos can be resolved from the config.
  #
  # GitHub supports two shapes:
  #   - Single-repo: merge.config.repo is set → one patrol.
  #   - Multi-repo: merge.config.repos is a list of repo names → one patrol per
  #     repo, all sharing the same owner. Used by workspaces like leotech whose
  #     acolytes work across multiple leo-technologies-llc/* repos and derive
  #     the per-rig repo from the rig's git remote at open time.
  defp patrol_repos(%Workspace{} = workspace) do
    config = workspace.config || %{}

    case get_in(config, ["merge", "strategy"]) do
      "github" ->
        owner = get_in(config, ["merge", "config", "owner"])
        repo = get_in(config, ["merge", "config", "repo"])
        repos = get_in(config, ["merge", "config", "repos"])

        cond do
          is_binary(owner) and owner != "" and is_binary(repo) and repo != "" ->
            ["#{owner}/#{repo}"]

          is_binary(owner) and owner != "" and is_list(repos) ->
            repos
            |> Enum.filter(&(is_binary(&1) and &1 != ""))
            |> Enum.map(&"#{owner}/#{&1}")

          true ->
            []
        end

      _ ->
        []
    end
  end

  defp patrol_interval_ms do
    Application.get_env(:arbiter, :pr_patrol_interval_ms, 60_000)
  end
end
