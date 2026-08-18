defmodule Arbiter.Workflows.PRPatrolSupervisor do
  @moduledoc """
  DynamicSupervisor for PRPatrol processes — one per (workspace, repo) pair
  configured for GitHub merges.

  Single-repo workspaces (those with `config["merge"]["config"]["repo"]` set)
  get exactly one PRPatrol, registered under their `workspace_id`.

  Multi-repo workspaces (no `repo` pinned in the merge config — only an
  `owner`) get one PRPatrol per repo, registered under
  `"workspace_id:owner/repo"`. The repo list is derived from the workspace's
  `repo_paths` map: each locally-checked-out repo's `origin` remote
  is resolved to an `"owner/repo"` slug via `RepoResolver`, the same mechanism
  the worker dispatch path uses. This covers the leotech workspace shape, whose
  repos are separate `leo-technologies-llc/*` repos that must each be patrolled
  independently — without this, leotech (a jira-tracker + github-merger
  workspace) got no patrol at all and Copilot review comments went unaddressed.

  Patrols are registered under `Arbiter.Workflows.PRPatrolRegistry`. Duplicate
  starts collapse to `{:error, {:already_started, pid}}`.

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts patrols for those with a GitHub merge config. New
  workspaces start their patrol(s) via the
  `Arbiter.Tasks.Workspace.Changes.StartPRPatrol` after_action hook.

  Both auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test`, enabled everywhere else.

  Poll interval is read from `:arbiter, :pr_patrol_interval_ms` (default 60s).

  ## Registry-key scheme and 1↔N transitions

  The registry key scheme depends on how many repos resolve for a workspace at
  call time. If a workspace's resolvable-repo count crosses 1↔N between
  restarts (a repo added or removed, or a previously-unreachable remote starts
  resolving), `start_patrol/2` automatically stops any stale patrol registered
  under the old scheme before starting new ones under the new scheme. This
  reconciliation prevents a ghost patrol from running under the wrong key after
  the repo count changes.

  ## Multi-repo workspace create-time deferral

  When a new multi-repo workspace is created, the `StartPRPatrol` after_action
  hook calls `start_patrol/2` immediately. If the workspace's repos are not yet
  checked out at that point, `repos_from_repo_paths/1` returns `[]` and the call
  returns `:skip` — the patrol is deferred to the next application boot via
  `start_for_existing_workspaces/0`. This is intentional: a freshly created
  multi-repo workspace has no repos on disk yet, so there is nothing to patrol.
  The boot-time enumeration catches it once the repos are present.

  ## Observable signals

  A `Logger.info` line is emitted for every patrol started or skipped, so
  operators can confirm which workspaces are covered without querying the
  `PRPatrolRegistry` directly.
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.RepoConfig, Tasks.Workspace}
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Workflows.{PatrolRepoScope, PRPatrol}

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
  one patrol registered under `workspace_id`. Multi-repo workspaces (repo
  derived per-repo from `repo_paths`) start one patrol per repo,
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
            "no repos resolvable (set merge.config.repo, or a repo_paths " <>
            "map whose repos have a github origin remote)"
        )

        :skip

      true ->
        reconcile_stale_registrations(workspace.id, repos)

        results =
          Enum.map(repos, fn repo ->
            registry_key =
              if length(repos) == 1, do: workspace.id, else: "#{workspace.id}:#{repo}"

            # Lazy-start gate (bd-7tr11p): only patrol a repo that actually has a
            # fleet-authored PR to watch. A repo with none costs nothing — no
            # process, no polling — until one is opened (the PatrolLifecycle
            # subscriber re-invokes this on the lifecycle event, and a running
            # patrol self-terminates once its last PR closes). Cheap DB read,
            # never a forge call, so an idle-fleet boot starts zero patrols.
            if PRPatrol.has_open_authored_pr?(workspace.id, repo) do
              start_repo(workspace, repo, registry_key, opts)
            else
              Logger.info(
                "PRPatrolSupervisor: skip patrol #{repo} workspace #{workspace.id} " <>
                  "(#{workspace.name}) — no open fleet-authored PR to watch"
              )

              :skip
            end
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Ensure a patrol is running for the repo a just-opened fleet PR belongs to,
  WITHOUT re-reading the database (bd-7tr11p). Called by the `PatrolLifecycle`
  subscriber on the lifecycle event: the event itself is proof that watched work
  exists, so this starts the repo's patrol optimistically rather than gating on
  a DB read that could race the not-yet-committed create/update. `ref` is the
  issue's `pr_ref`; the repo is resolved from it against the workspace config.
  Idempotent (a running patrol collapses to `{:error, {:already_started, pid}}`);
  returns `:skip` when the ref names no repo this workspace patrols.
  """
  @spec ensure_started(Workspace.t(), String.t()) ::
          DynamicSupervisor.on_start_child() | :skip
  def ensure_started(%Workspace{} = workspace, ref) when is_binary(ref) do
    adapter = resolve_adapter(workspace)
    repos = patrol_repos(workspace)

    with false <- is_nil(adapter) or not function_exported?(adapter, :list_open, 0),
         repo when is_binary(repo) <- resolve_demand_repo(ref, repos) do
      registry_key = if length(repos) == 1, do: workspace.id, else: "#{workspace.id}:#{repo}"
      start_repo(workspace, repo, registry_key, [])
    else
      _ -> :skip
    end
  end

  # Resolve the repo a demand-start ref belongs to, against the workspace's
  # patrolled repos. A qualified ref must name one of them; a bare ref can only
  # come from a single-repo workspace, so it maps to the sole repo.
  defp resolve_demand_repo(ref, repos) do
    case PatrolRepoScope.repo_of_ref(ref) do
      {:ok, slug} -> if slug in repos, do: slug, else: nil
      :bare -> if match?([_], repos), do: hd(repos), else: nil
    end
  end

  # Start one repo's patrol under its registry key. Shared by the gated boot
  # loop and the demand-start path. Idempotent via the DynamicSupervisor.
  defp start_repo(workspace, repo, registry_key, opts) do
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
  end

  @doc """
  Return the pid of the PRPatrol registered under `workspace_id`, or `nil`.

  Works for single-repo workspaces (registered under their `workspace_id`).
  For multi-repo workspaces, each patrol is registered under
  `"workspace_id:owner/repo"` — use `whereis_all/1` to enumerate all patrols
  for a workspace regardless of naming scheme.
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
  (registered under `"workspace_id:owner/repo"`). Returns an empty list when no
  patrols are running for the workspace.
  """
  @spec whereis_all(String.t()) :: [{String.t(), pid()}]
  def whereis_all(workspace_id) when is_binary(workspace_id) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _pid} ->
      key == workspace_id or String.starts_with?(key, workspace_id <> ":")
    end)
  end

  @doc """
  Nudge every running patrol for a workspace to re-check whether its repo still
  has watched work (bd-7tr11p). Sends each an async `:recheck`; a patrol whose
  last fleet PR has closed terminates itself (`:transient`, so it stays down).
  Called by the `PatrolLifecycle` subscriber when a watched item closes, so an
  idle repo's patrol is reaped promptly rather than on its next scheduled tick.
  """
  @spec recheck_all(String.t()) :: :ok
  def recheck_all(workspace_id) when is_binary(workspace_id) do
    for {_key, pid} <- whereis_all(workspace_id), is_pid(pid) do
      send(pid, :recheck)
    end

    :ok
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

  # Stop any patrols registered under the opposite naming scheme for this
  # workspace. Called before starting new patrols so that a 1→N or N→1
  # transition in resolvable-repo count doesn't leave a ghost patrol running
  # under the old registry key.
  defp reconcile_stale_registrations(workspace_id, repos) do
    if length(repos) == 1 do
      # Moving to (or staying at) single-repo: terminate any composite-keyed patrols
      @registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.each(fn {key, pid} ->
        if String.starts_with?(key, workspace_id <> ":") do
          Logger.info(
            "PRPatrolSupervisor: stopping stale patrol #{key} (registry scheme changed to single-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)
        end
      end)
    else
      # Moving to (or staying at) multi-repo: terminate any bare-key patrol
      case Registry.lookup(@registry, workspace_id) do
        [{pid, _}] ->
          Logger.info(
            "PRPatrolSupervisor: stopping stale patrol #{workspace_id} (registry scheme changed to multi-repo)"
          )

          DynamicSupervisor.terminate_child(__MODULE__, pid)

        _ ->
          :ok
      end
    end
  end

  # Resolve the merge adapter for a workspace, or nil on unknown strategy.
  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
    # Load the adapter before `start_patrol/2`'s `function_exported?/3` guard
    # inspects it: `function_exported?/3` reports false for a not-yet-loaded
    # module without triggering a load, so under interactive code loading
    # (`mix test`) the guard could spuriously skip a perfectly valid patrol.
    # See bd-1hn1qw.
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  # Derive the list of "owner/repo" strings to patrol for this workspace.
  # Returns an empty list when no repos can be resolved.
  #
  # GitHub supports two shapes:
  #   - Single-repo: merge.config.repo is set → one patrol against owner/repo.
  #   - Multi-repo: no repo pinned in the merge config → one patrol per repo,
  #     with each repo's "owner/repo" derived from its `origin` remote. The repo
  #     list comes from the workspace's repo_paths map — the same
  #     source the worker dispatch path resolves worktrees from. Used by
  #     workspaces like leotech, whose repos are distinct leo-technologies-llc/*
  #     repos.
  defp patrol_repos(%Workspace{} = workspace) do
    config = workspace.config || %{}

    case get_in(config, ["merge", "strategy"]) do
      "github" ->
        owner = get_in(config, ["merge", "config", "owner"])
        repo = get_in(config, ["merge", "config", "repo"])

        if is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
          ["#{owner}/#{repo}"]
        else
          repos_from_repo_paths(config)
        end

      _ ->
        []
    end
  end

  # Resolve every locally-checked-out repo's `origin` remote into an
  # "owner/repo" slug. Best-effort: a repo whose path is missing, isn't a git
  # checkout, or whose remote can't be parsed is logged and skipped.
  defp repos_from_repo_paths(config) do
    case Map.get(config, "repo_paths") do
      repo_map when is_map(repo_map) ->
        repo_map
        |> Map.values()
        |> Enum.map(&RepoConfig.repo_path_from_config/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn path ->
          case RepoResolver.from_remote(path) do
            {:ok, {owner, repo}} ->
              ["#{owner}/#{repo}"]

            {:error, err} ->
              Logger.info(
                "PRPatrolSupervisor: could not derive repo for path #{path} " <>
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
    Application.get_env(:arbiter, :pr_patrol_interval_ms, 60_000)
  end
end
