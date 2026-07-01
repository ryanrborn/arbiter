defmodule Arbiter.Workflows.MergedPRFinalizer do
  @moduledoc """
  Per-repo GenServer that sweeps open arbiter tasks with a `pr_ref` and
  finalizes those whose PR was merged on GitHub outside arbiter's merge queue
  (or after the worker/Watchdog for that task was gone).

  ## Problem this solves

  When a PR is merged manually on GitHub — or merged after the worker and its
  `restart: :temporary` Watchdog have already exited — nothing polls for the
  merge. The linked Jira ticket stalls at "In Code Review" and the arbiter task
  stays open indefinitely. This was the root cause of the VR-17892 symptom.

  ## Detection

  On each tick the finalizer:

    1. Queries `Issue` for tasks in this workspace with `pr_ref != nil` and
       `status != :closed`.
    2. For each, calls `adapter.get(pr_ref)` — the same forge call the Watchdog
       uses — and checks whether `status == :merged`.
    3. If merged, fires `Arbiter.Trackers.Sync.lifecycle(task, :merged)` and
       then closes the task with `close_upstream: true`.

  Tasks whose PR returns an API error (e.g. 404 from a different repo in a
  multi-repo workspace) are silently skipped — the finalizer for the correct
  repo picks them up.

  ## Relationship to PRPatrol

  PRPatrol queries `list_open()` (open PRs only, never merged) and deliberately
  uses `tracker_type: :none` on its follow-up tasks to avoid transitioning
  merged PRs. This module works the orthogonal path: it queries open **arbiter
  tasks** that have their own `pr_ref`, and finalizes exactly those.

  In addition, this module sweeps PRPatrol follow-up tasks that were never
  assigned their own `pr_ref` but whose **source PR** has since merged. Two
  formats are handled:

    * Modern: `source_pr` field set (added by bd-ci2jl2, `tracker_type: :none`).
    * Legacy: `tracker_type: :github`, `tracker_ref` is a bare PR number,
      `source_pr` nil (pre-bd-ci2jl2 format).

  **Critical guard:** these tasks are closed local-only — `Sync.lifecycle` is
  NOT invoked. For modern follow-ups `tracker_type: :none` would already
  short-circuit it, but for legacy tasks with `tracker_type: :github` the
  `tracker_ref` is a merged-PR number, and transitioning a merged PR returns
  `Validation Failed` (bd-ci2jl2 hazard). Closing via `close_upstream: false`
  (the default) avoids any upstream write-back.

  ## Idempotency

  `Sync.lifecycle/2` is best-effort and logs quietly on a benign non-transition
  (`:transition_not_found`, `:status_unmapped`). The `:close` action on an
  already-closed task is blocked by `GuardStatus` and returns an error, which
  is caught and logged without crashing the sweep.

  ## Lifecycle

  Not in `Application.children`. Started per-workspace via
  `MergedPRFinalizerSupervisor` — one instance per (workspace, repo).
  Test convenience: `tick/1` forces a synchronous sweep.
  """

  use GenServer

  alias Arbiter.Tasks.Issue
  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Trackers.Sync
  require Ash.Query
  require Logger

  @default_interval_ms 120_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_tick_at: nil
  ]

  # ---- public API ----

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously force a finalizer sweep. Returns :ok after the sweep completes."
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

  def handle_call(:state, _from, state) do
    {:reply,
     %{
       repo: state.repo,
       workspace_id: state.workspace_id,
       interval_ms: state.interval_ms,
       ticks: state.ticks,
       last_tick_at: state.last_tick_at
     }, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- sweep logic ----

  defp do_tick(state) do
    result =
      with %Workspace{} <- state.workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(state.workspace),
           true <- function_exported?(adapter, :get, 1),
           :ok <- Mergers.prepare_with_repo(state.workspace, state.repo),
           {:ok, pr_ref_tasks} <- open_tasks_with_pr_ref(state.workspace_id),
           {:ok, follow_up_tasks} <- open_follow_up_tasks(state.workspace_id),
           {:ok, legacy_tasks} <- open_legacy_pr_tracker_tasks(state.workspace_id) do
        Enum.each(pr_ref_tasks, &maybe_finalize(&1, adapter))
        Enum.each(follow_up_tasks, &maybe_finalize_follow_up(&1, adapter))
        Enum.each(legacy_tasks, &maybe_finalize_follow_up(&1, adapter))
        :ok
      else
        _ -> :noop
      end

    _ = result
    %{state | ticks: state.ticks + 1, last_tick_at: DateTime.utc_now()}
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  defp open_tasks_with_pr_ref(workspace_id) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        not is_nil(pr_ref) and
        status != :closed
    )
    |> Ash.read()
  end

  # Modern PRPatrol follow-ups: source_pr set, tracker_type: :none (bd-ci2jl2).
  # Excludes tasks that already have their own PR opened (pr_ref set) — those
  # are owned by the pr_ref pass. Also excludes ReviewPatrol engagements
  # (review_only: true) which share the source_pr field but must never be
  # closed by this sweep (disjointness invariant, see review_patrol.ex:270).
  defp open_follow_up_tasks(workspace_id) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        not is_nil(source_pr) and
        is_nil(pr_ref) and
        review_only != true and
        status != :closed
    )
    |> Ash.read()
  end

  # Legacy PRPatrol follow-ups: pre-bd-ci2jl2 format used tracker_type: :github
  # and stored the source PR number in tracker_ref. We only sweep tasks that
  # have no source_pr (already handled above) and no pr_ref (handled by the
  # pr_ref pass). The adapter.get call is the safety net: if tracker_ref is
  # not a PR number (e.g. a real GitHub issue ref) the GitHub API returns 404
  # and we skip it harmlessly.
  defp open_legacy_pr_tracker_tasks(workspace_id) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        tracker_type == :github and
        not is_nil(tracker_ref) and
        is_nil(source_pr) and
        is_nil(pr_ref) and
        status != :closed
    )
    |> Ash.read()
  end

  defp maybe_finalize(%Issue{pr_ref: pr_ref} = task, adapter) do
    with {:ok, %{status: :merged}} <- adapter.get(pr_ref) do
      finalize(task)
    else
      # PR is open, approved-but-not-merged, closed without merge, or API error
      # (including 404 for a PR in a different repo). All are no-ops.
      _ -> :noop
    end
  end

  defp finalize(%Issue{} = task) do
    Logger.info(
      "MergedPRFinalizer: detected externally-merged PR #{task.pr_ref} for task=#{task.id} " <>
        "(tracker=#{task.tracker_type} ref=#{task.tracker_ref}) — finalizing"
    )

    Sync.lifecycle(task, :merged)

    case Ash.update(task, %{close_upstream: true}, action: :close) do
      {:ok, _} ->
        Logger.info("MergedPRFinalizer: closed task=#{task.id}")

      {:error, reason} ->
        Logger.warning("MergedPRFinalizer: failed to close task=#{task.id}: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizer: error finalizing task=#{task.id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Determines the source PR ref for a follow-up task (modern: source_pr,
  # legacy: tracker_ref) and closes the task local-only if the source PR merged.
  defp maybe_finalize_follow_up(
         %Issue{source_pr: source_pr, tracker_ref: tracker_ref} = task,
         adapter
       ) do
    ref = source_pr || tracker_ref

    with {:ok, %{status: :merged}} <- adapter.get(ref) do
      finalize_follow_up(task, ref)
    else
      _ -> :noop
    end
  end

  # Closes a PRPatrol follow-up task local-only: no Sync.lifecycle, no
  # close_upstream. The source PR is a merged PR number — calling Sync.lifecycle
  # on it would attempt a tracker transition on a merged PR and fail with
  # Validation Failed (bd-ci2jl2 hazard).
  defp finalize_follow_up(%Issue{} = task, source_ref) do
    Logger.info(
      "MergedPRFinalizer: source PR #{source_ref} merged — closing follow-up task=#{task.id} " <>
        "(tracker=#{task.tracker_type} source_pr=#{task.source_pr} tracker_ref=#{task.tracker_ref})"
    )

    case Ash.update(task, %{}, action: :close) do
      {:ok, _} ->
        Logger.info("MergedPRFinalizer: closed follow-up task=#{task.id}")

      {:error, reason} ->
        Logger.warning(
          "MergedPRFinalizer: failed to close follow-up task=#{task.id}: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizer: error closing follow-up task=#{task.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
