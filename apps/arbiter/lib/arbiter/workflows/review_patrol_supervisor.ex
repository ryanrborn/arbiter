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
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Workflows.{PatrolRepoScope, ReviewPatrol}

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
            "no repos resolvable (set merge.config.repo, or a repo_paths " <>
            "map whose rigs have a github origin remote)"
        )

        :skip

      true ->
        reconcile_stale_registrations(workspace.id, repos)

        results =
          Enum.map(repos, fn repo ->
            registry_key =
              if length(repos) == 1, do: workspace.id, else: "#{workspace.id}:#{repo}"

            cond do
              off_mode?(workspace, repo) ->
                stop_if_running(registry_key)

                Logger.info(
                  "ReviewPatrolSupervisor: skip patrol #{repo} workspace #{workspace.id} " <>
                    "(#{workspace.name}) — review_automation resolves to :off for this repo"
                )

                :skip

              # Lazy-start gate (bd-7tr11p): only patrol a repo that actually has
              # an open engagement to watch. A repo with none costs nothing — no
              # process, no polling — until one is opened (the PatrolLifecycle
              # subscriber re-invokes this on the lifecycle event, and a running
              # patrol self-terminates once its last engagement closes). Cheap DB
              # read, never a forge call, so an idle-fleet boot starts zero
              # patrols.
              not ReviewPatrol.has_open_engagement?(workspace.id, repo) ->
                Logger.info(
                  "ReviewPatrolSupervisor: skip patrol #{repo} workspace #{workspace.id} " <>
                    "(#{workspace.name}) — no open engagement to watch"
                )

                :skip

              true ->
                start_repo(workspace, repo, registry_key, opts)
            end
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Ensure a patrol is running for the repo a just-opened engagement belongs to,
  WITHOUT re-reading the database (bd-7tr11p). Called by the `PatrolLifecycle`
  subscriber on the lifecycle event: the event itself is proof that an
  engagement exists, so this starts the repo's patrol optimistically rather than
  gating on a DB read that could race the not-yet-committed create. `ref` is the
  engagement's `source_pr`; the repo is resolved from it against the workspace
  config. Still respects `:off` mode (an off repo is never patrolled).
  Idempotent; returns `:skip` when the ref names no repo this workspace patrols
  or that repo is `:off`.
  """
  @spec ensure_started(Workspace.t(), String.t()) ::
          DynamicSupervisor.on_start_child() | :skip
  def ensure_started(%Workspace{} = workspace, ref) when is_binary(ref) do
    adapter = resolve_adapter(workspace)
    repos = patrol_repos(workspace)

    with false <- is_nil(adapter) or not function_exported?(adapter, :get, 1),
         repo when is_binary(repo) <- resolve_demand_repo(ref, repos),
         false <- off_mode?(workspace, repo) do
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

    result = DynamicSupervisor.start_child(__MODULE__, {ReviewPatrol, child_opts})

    Logger.info(
      "ReviewPatrolSupervisor: patrol #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
    )

    result
  end

  # A repo whose LIVE `review_automation.repo_overrides[rig_name]` (or,
  # absent an override, `review_automation.default`) resolves to `:off` has no
  # reviewer we'd ever dispatch against it — ReviewPatrol's own tick logic
  # already downgrades an in-flight engagement to no-dispatch behavior in this
  # case (see `ReviewPatrol.automation_mode/3`), but the PATROL PROCESS ITSELF
  # still started and ticked GitHub every interval regardless (bd-4brb2j: this
  # was true of both `voice_biometrics` at `:flag` and `atlas` at
  # `:report_only` in the incident — closing that gap for the strictly-worse
  # `:off` case here is the highest-value, lowest-risk slice of that finding).
  # Checked at author-independent granularity (`repo_override_mode/2`, no PR
  # author needed), same as ReviewPatrol's own live re-check.
  defp off_mode?(%Workspace{} = workspace, repo) do
    rig_name = ReviewPatrol.rig_name_for_repo(workspace, repo)

    case ReviewAutomation.repo_override_mode(workspace.config, rig_name) do
      :off -> true
      nil -> default_off?(workspace.config)
      _ -> false
    end
  end

  defp default_off?(%{"review_automation" => %{"default" => default}}),
    do: ReviewAutomation.normalize(default) == :off

  defp default_off?(_config), do: false

  defp stop_if_running(registry_key) do
    case Registry.lookup(@registry, registry_key) do
      [{pid, _}] ->
        Logger.info(
          "ReviewPatrolSupervisor: stopping patrol #{registry_key} — review_automation flipped to :off"
        )

        DynamicSupervisor.terminate_child(__MODULE__, pid)

      _ ->
        :ok
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

  @doc """
  Nudge every running patrol for a workspace to re-check whether its repo still
  has an open engagement (bd-7tr11p). Sends each an async `:recheck`; a patrol
  whose last engagement has closed terminates itself (`:transient`, so it stays
  down). Called by the `PatrolLifecycle` subscriber when a watched item closes,
  so an idle repo's patrol is reaped promptly rather than on its next scheduled
  tick.
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
          repos_from_repo_paths(config)
        end

      _ ->
        []
    end
  end

  defp repos_from_repo_paths(config) do
    case Map.get(config, "repo_paths") do
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
