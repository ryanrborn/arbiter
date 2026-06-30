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
           {:ok, tasks} <- open_tasks_with_pr_ref(state.workspace_id) do
        Enum.each(tasks, &maybe_finalize(&1, adapter))
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
    result =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and
          not is_nil(pr_ref) and
          status != :closed
      )
      |> Ash.read()

    result
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

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
