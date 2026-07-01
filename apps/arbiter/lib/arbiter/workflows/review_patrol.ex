defmodule Arbiter.Workflows.ReviewPatrol do
  @moduledoc """
  Per-(workspace, repo) GenServer that polls **open review engagements** and
  drives their lifecycle. The reviewer-side mirror of `PRPatrol`: where PRPatrol
  watches PRs the fleet *authored* and files follow-up work, ReviewPatrol watches
  PRs the fleet is *reviewing* (long-lived `review_only` engagements) and keeps
  the engagement in step with the upstream PR.

  ## What is an "engagement"

  A review engagement is an `Issue` with `review_only == true` and a `source_pr`
  set — a long-lived task created when the fleet is asked to review someone
  else's PR (bd-cw3w9p made these tasks long-lived: the Driver / MergeQueue no
  longer auto-close them after the first verdict, so ReviewPatrol owns closure).

  ## Query / dedup

  Each tick selects `review_only == true and not is_nil(source_pr) and
  status != :closed`, scoped to the patrol's `workspace_id`. The `review_only`
  predicate is the hard boundary that keeps ReviewPatrol from colliding with
  PRPatrol's author-side follow-ups: those are filed with `review_only == false`
  (they take the normal implementation path), so they are never selected here.

  ## Per-engagement action

  For each engagement, `adapter.get(source_pr)`:

    * `:merged` or `:closed` → **terminate the engagement**: close the task via
      the `:close` action. Because the task is `review_only`, `SyncTracker`
      short-circuits and the close fires ZERO tracker writes (bd-6xaaam). The
      query already excludes `:closed` tasks, so re-ticking an already-terminated
      engagement is a no-op (idempotent).

    * `:open` → record the PR head SHA into `last_reviewed_sha` **only if unset**.
      Otherwise no-op — new-commit re-review and its guards land in task D.

    * any adapter error → no-op for that engagement (logged); the tick still
      completes and bumps the counter so callers can see the patrol is alive.

  ## Hard invariant

  ReviewPatrol may only ever dispatch `review_only` sub-runs. It must NEVER call
  the Work / implementation path (`Arbiter.Worker.start/1` for a normal task).
  This skeleton dispatches nothing at all; task D adds `review_only` re-review
  sub-runs, and that is the only kind of run this module may ever start.

  ## Lifecycle

  Not in `Application.children` directly — started per-(workspace, repo) by
  `Arbiter.Workflows.ReviewPatrolSupervisor`, gated by the same
  `:auto_start_refineries` flag PRPatrol uses. Registered in the SEPARATE
  `Arbiter.Workflows.ReviewPatrolRegistry` (never PRPatrol's).

  Test convenience: `tick/1` forces a synchronous patrol cycle without waiting
  for the next interval.
  """

  use GenServer

  alias Arbiter.Tasks.Issue
  alias Arbiter.{Mergers, Tasks.Workspace}
  require Ash.Query
  require Logger

  @default_interval_ms 60_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_terminated: [],
    last_tick_at: nil
  ]

  # ---- public API ----

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously force a patrol cycle. Returns :ok after the cycle completes."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Snapshot of internal state."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    workspace =
      case Ash.get(Workspace, workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    state = %__MODULE__{
      repo: repo,
      workspace_id: workspace_id,
      workspace: workspace,
      interval_ms: interval_ms
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    new_state = do_tick(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:state, _from, state),
    do:
      {:reply,
       %{
         repo: state.repo,
         workspace_id: state.workspace_id,
         interval_ms: state.interval_ms,
         ticks: state.ticks,
         last_terminated: state.last_terminated,
         last_tick_at: state.last_tick_at
       }, state}

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- tick logic ----

  defp do_tick(state) do
    # Re-fetch the workspace on every tick so config changes take effect
    # immediately without a GenServer restart (mirrors PRPatrol).
    workspace =
      case Ash.get(Workspace, state.workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    terminated =
      with %Workspace{} <- workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :get, 1),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo) do
        state.workspace_id
        |> open_engagements()
        |> Enum.map(&process_engagement(&1, adapter))
        |> Enum.filter(& &1)
      else
        # On any failure (missing workspace, unsupported adapter), no-op the
        # cycle but still bump the tick counter below so the patrol is observable.
        _ -> []
      end

    %{
      state
      | ticks: state.ticks + 1,
        last_tick_at: DateTime.utc_now(),
        last_terminated: terminated,
        workspace: workspace
    }
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)

    # Force the adapter module to load before the `function_exported?/3` guard
    # inspects it: the guard returns false for a not-yet-loaded module without
    # triggering a load, so under interactive code loading (`mix test`) it would
    # spuriously no-op the whole tick. Releases preload all modules, masking
    # this — but the guard must not depend on prior load order. See bd-1hn1qw.
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  # OPEN review engagements for this workspace: review_only tasks with a linked
  # source PR that are not yet closed. The `review_only == true` filter is what
  # keeps this disjoint from PRPatrol's author-side follow-ups (review_only ==
  # false), so the two patrols never act on each other's tasks.
  defp open_engagements(workspace_id) do
    Issue
    |> Ash.Query.filter(
      review_only == true and not is_nil(source_pr) and status != :closed and
        workspace_id == ^workspace_id
    )
    |> Ash.read!()
  rescue
    _ -> []
  end

  # Returns the engagement id when it was terminated this tick, otherwise nil.
  defp process_engagement(%Issue{source_pr: source_pr} = engagement, adapter)
       when is_binary(source_pr) and source_pr != "" do
    case adapter.get(source_pr) do
      {:ok, %{status: status}} when status in [:merged, :closed] ->
        terminate_engagement(engagement, status)

      {:ok, %{status: :open} = pr} ->
        maybe_record_head_sha(engagement, pr)
        nil

      {:ok, _other} ->
        nil

      {:error, reason} ->
        Logger.info(
          "ReviewPatrol: get(#{source_pr}) failed for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  defp process_engagement(_engagement, _adapter), do: nil

  # Close the engagement's task. review_only == true, so SyncTracker skips every
  # tracker write (bd-6xaaam): terminating an engagement never touches the
  # upstream PR / issue we don't own.
  defp terminate_engagement(%Issue{} = engagement, pr_status) do
    case Ash.update(engagement, %{reason: "source PR #{pr_status}"}, action: :close) do
      {:ok, _closed} ->
        Logger.info(
          "ReviewPatrol: terminated engagement #{engagement.id} (source PR #{engagement.source_pr} #{pr_status})"
        )

        engagement.id

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: failed to terminate engagement #{engagement.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  # Record the PR head SHA the first time we see the engagement (last_reviewed_sha
  # unset). Once set, this is a no-op here — new-commit re-review lands in task D.
  defp maybe_record_head_sha(%Issue{last_reviewed_sha: nil} = engagement, %{head_sha: sha})
       when is_binary(sha) and sha != "" do
    case Ash.update(engagement, %{last_reviewed_sha: sha}, action: :update) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: failed to record head SHA for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp maybe_record_head_sha(_engagement, _pr), do: :ok

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
