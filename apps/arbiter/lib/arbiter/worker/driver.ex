defmodule Arbiter.Worker.Driver do
  @moduledoc """
  Drives a task to completion. Has two modes:

  ### Workflow mode (default)

  Ticks `Arbiter.Workflows.Machine` forward and mirrors its progress onto
  the paired `Arbiter.Worker`. Closes the task when the workflow
  completes. Used for bookkeeping-only workers.

  ### Claude-driven mode (`claude_driven: true`)

  A Claude subprocess is doing the real work; the Driver does NOT tick the
  Machine. Instead it polls the worker's status and closes the task when
  the worker reaches `:completed` (typically triggered by Claude printing
  `arb done` on stdout — see `Worker.ClaudeSession`).

  This mode resolves the Driver/Claude race that `arb dispatch --with-claude`
  exposed: the bookkeeping workflow used to finish in ~500ms and close the
  task before Claude had time to respond.

  ## Lifecycle (workflow mode)

  - On start: schedules the first tick immediately.
  - On each tick: calls `Machine.advance/1` and reacts:
    - `{:ok, :completed}` → `Worker.complete/2`, close the task, stop.
    - `{:ok, next_step}` → `Worker.advance/2`, schedule next tick.
    - `{:error, reason}` → `Worker.fail/2`, stop (task remains `:in_progress`).

  ## Lifecycle (claude-driven mode)

  - On start: schedules the first worker check.
  - On each check: reads worker status:
    - `:completed` → close the task, optionally cleanup worktree, stop.
    - `:failed` → log, stop (task remains `:in_progress` for inspection).
    - `:idle | :running | :awaiting | :awaiting_review` → schedule next check
      (`:awaiting_review` is the brief window after the worker's `arb done`
      opens an MR; the Watchdog, not the Driver, drives it to terminal).

  ## Shared lifecycle

  - On worker or machine `:DOWN`: stop cleanly; if the machine died first
    (workflow mode), mark the worker `:failed`.

  ## Safety backstops

  `:max_ticks` bounds the loop. Defaults differ by mode:
    - workflow mode: 50 ticks × 100ms = 5 seconds (plenty for no-op steps).
    - claude-driven mode: 1800 ticks × 1000ms = 30 minutes (room for real
      Claude work; tune via the `:max_ticks` and `:interval_ms` opts).
  """

  use GenServer
  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workflows.Machine

  @workflow_default_interval_ms 100
  @workflow_default_max_ticks 50

  @claude_default_interval_ms 1_000
  @claude_default_max_ticks 1_800

  @type opts :: [
          task_id: String.t(),
          worker_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          interval_ms: non_neg_integer(),
          max_ticks: non_neg_integer(),
          worktree_path: String.t() | nil,
          cleanup_worktree: boolean(),
          claude_driven: boolean()
        ]

  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.Supervisor, {__MODULE__, opts})
  end

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    claude_driven = Keyword.get(opts, :claude_driven, false)

    state = %{
      task_id: Keyword.fetch!(opts, :task_id),
      worker_pid: Keyword.fetch!(opts, :worker_pid),
      machine_id: Keyword.fetch!(opts, :machine_id),
      machine_pid: Keyword.fetch!(opts, :machine_pid),
      claude_driven: claude_driven,
      interval_ms: Keyword.get(opts, :interval_ms, default_interval_for(claude_driven)),
      max_ticks: Keyword.get(opts, :max_ticks, default_max_ticks_for(claude_driven)),
      worktree_path: Keyword.get(opts, :worktree_path),
      cleanup_worktree: Keyword.get(opts, :cleanup_worktree, false),
      ticks: 0
    }

    Process.monitor(state.worker_pid)
    Process.monitor(state.machine_pid)

    schedule_first(state)
    {:ok, state}
  end

  defp default_interval_for(true), do: @claude_default_interval_ms
  defp default_interval_for(false), do: @workflow_default_interval_ms

  defp default_max_ticks_for(true), do: @claude_default_max_ticks
  defp default_max_ticks_for(false), do: @workflow_default_max_ticks

  defp schedule_first(%{claude_driven: true}), do: Process.send_after(self(), :check_worker, 0)
  defp schedule_first(%{claude_driven: false}), do: Process.send_after(self(), :tick, 0)

  @impl true
  def handle_info(:tick, %{ticks: t, max_ticks: m} = state) when t >= m do
    Logger.warning("Worker.Driver hit max_ticks=#{m} for task=#{state.task_id}; stopping")

    safe(fn -> Worker.fail(state.worker_pid, {:driver_timeout, m}) end)
    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  def handle_info(:check_worker, %{ticks: t, max_ticks: m} = state) when t >= m do
    # Even at max_ticks, close a completed worker rather than leaving the task
    # stranded. This handles the race where the Watchdog calls Worker.complete
    # in the same window the Driver's tick budget expires (bd-d1jp4r).
    case safe_worker_state(state.worker_pid) do
      %{status: :completed} = worker_state ->
        close_task(state.task_id, should_close_upstream_for_task(state.task_id, worker_state))
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{status: status} when status in [:awaiting_review_gate, :awaiting_review] ->
        # bd-7b46wd: the tick budget was spent on active worker work, but the
        # worker has since handed off to the ReviewGate (review gate) or the
        # Watchdog (merge poller). Both own the terminal transition and have
        # their own watchdogs, so giving up here would strand a task that is
        # legitimately mid-merge. Keep waiting for :completed rather than
        # stopping — same reasoning as the pre-max_ticks handler below.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, state}

      _ ->
        Logger.warning(
          "Worker.Driver (claude_driven) hit max_ticks=#{m} for task=#{state.task_id}; stopping"
        )

        maybe_cleanup_worktree(state)
        {:stop, :normal, state}
    end
  end

  def handle_info(:check_worker, state) do
    case safe_worker_state(state.worker_pid) do
      %{status: :completed} = worker_state ->
        close_upstream = should_close_upstream_for_task(state.task_id, worker_state)
        close_task(state.task_id, close_upstream)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{status: :failed} ->
        Logger.warning(
          "Worker.Driver (claude_driven): worker failed for task=#{state.task_id}; leaving task :in_progress"
        )

        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{status: status} when status in [:idle, :running, :awaiting] ->
        # Active states — Claude is working; count against the tick budget.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      %{status: status} when status in [:awaiting_review_gate, :awaiting_review] ->
        # :awaiting_review_gate — a distinct reviewer worker (ReviewGate) is
        # evaluating the diff; it will report a verdict that merges or parks.
        # :awaiting_review — the Watchdog is polling the forge for merge/approval;
        # it drives the terminal transition, not the Driver.
        # Neither state is "Claude stuck" — they're externally owned handoffs.
        # Don't burn tick budget here: the Watchdog (bd-d1jp4r) and ReviewGate each
        # have their own watchdogs; the Driver just needs to stay alive until
        # Worker.complete fires.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, state}

      nil ->
        # Worker snapshot unavailable (process likely dead) — the :DOWN
        # handler will fire next, just stop trying for now.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}
    end
  end

  def handle_info(:tick, state) do
    case safe_advance(state.machine_pid) do
      {:ok, :completed} ->
        safe(fn -> Worker.complete(state.worker_pid, :workflow_completed) end)
        close_task(state.task_id)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      {:ok, next_step} when is_atom(next_step) ->
        safe(fn -> Worker.advance(state.worker_pid, next_step) end)
        schedule_tick(state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      {:error, reason} ->
        Logger.warning(
          "Worker.Driver: machine.advance error for task=#{state.task_id}: #{inspect(reason)}"
        )

        safe(fn -> Worker.fail(state.worker_pid, reason) end)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{worker_pid: pid} = state) do
    Logger.warning("Worker.Driver: worker died for task=#{state.task_id}")
    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{machine_pid: pid} = state) do
    Logger.warning("Worker.Driver: machine died for task=#{state.task_id}")
    safe(fn -> Worker.fail(state.worker_pid, :machine_died) end)
    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    maybe_cleanup_worktree(state)
  end

  # ---- internals ---------------------------------------------------------

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp safe_advance(machine_pid) do
    Machine.advance(machine_pid)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    # Machine process is gone — normalize to the same reason the :DOWN handler produces.
    :exit, {:noproc, _} -> {:error, :machine_died}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_worker_state(pid) do
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp should_close_upstream_for_task(task_id, worker_state) do
    # bd-6xaaam: review-only workers never transition a tracker issue they
    # don't own — even if the task has a tracker_ref. The flag is stamped on
    # the Issue by Dispatch when review: true, and echoed in worker meta.
    if review_only_worker?(worker_state) do
      false
    else
      # Pass close_upstream: true if either:
      # 1. there's an mr_ref (existing logic), OR
      # 2. the task has a tracker_ref (need to sync upstream on close)
      case should_close_upstream(worker_state) do
        true ->
          true

        false ->
          # Check if the task has a tracker_ref that needs syncing
          case Ash.get(Issue, task_id) do
            {:ok, task} ->
              has_tracker_ref?(task)

            :error ->
              false
          end
      end
    end
  rescue
    _ -> false
  end

  defp review_only_worker?(%{meta: %{review_only: true}}), do: true
  defp review_only_worker?(%{meta: %{"review_only" => true}}), do: true
  defp review_only_worker?(_), do: false

  defp has_tracker_ref?(%Issue{tracker_ref: ref, tracker_type: type})
       when is_binary(ref) and ref != "" and type != :none do
    true
  end

  defp has_tracker_ref?(_), do: false

  defp should_close_upstream(%{mr_ref: mr_ref}) when is_binary(mr_ref) and mr_ref != "", do: true
  defp should_close_upstream(_), do: false

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp close_task(task_id, close_upstream \\ false) do
    with {:ok, task} <- Ash.get(Issue, task_id) do
      attrs =
        %{}
        |> then(fn a -> if close_upstream, do: Map.put(a, :close_upstream, true), else: a end)

      case Ash.update(task, attrs, action: :close) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Logger.warning("Worker.Driver: failed to close task #{task_id}: #{inspect(err)}")
          :error
      end
    else
      err ->
        Logger.warning("Worker.Driver: failed to close task #{task_id}: #{inspect(err)}")
        :error
    end
  end

  # Best-effort worktree cleanup after a successful workflow.
  #
  # Skipped when:
  #   - `cleanup_worktree` is false (default)
  #   - `worktree_path` is nil (no worktree was provisioned)
  #   - the worktree has uncommitted changes (operator should inspect)
  #
  # Failures are logged but never propagated — the task is already closed
  # and the workflow is done, so we don't want to crash the Driver over a
  # cleanup hiccup.
  defp maybe_cleanup_worktree(%{cleanup_worktree: false}), do: :ok
  defp maybe_cleanup_worktree(%{worktree_path: nil}), do: :ok

  defp maybe_cleanup_worktree(%{worktree_path: path, task_id: task_id}) do
    cond do
      # The task's :close after_action already removed the worktree (see
      # Arbiter.Tasks.Issue.Changes.CleanupWorktree) — nothing left to do.
      # Returning :ok silently keeps the legacy Driver-side path from
      # logging a warning about a path that is already gone.
      not File.dir?(path) ->
        :ok

      worktree_dirty?(path, task_id) ->
        Logger.info(
          "Worker.Driver: worktree has uncommitted changes for task=#{task_id}; skipping cleanup"
        )

      worktree_ahead_of_base?(path, task_id) ->
        Logger.info(
          "Worker.Driver: worktree has commits ahead of base for task=#{task_id}; skipping cleanup"
        )

      true ->
        case Worktree.cleanup(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Worker.Driver: cleanup_worktree failed for task=#{task_id}: #{inspect(reason)}"
            )
        end
    end

    :ok
  end

  defp worktree_dirty?(path, task_id) do
    case Worktree.has_uncommitted?(path) do
      {:ok, dirty} ->
        dirty

      {:error, reason} ->
        Logger.warning(
          "Worker.Driver: cleanup-dirty-probe failed for task=#{task_id}: #{inspect(reason)}"
        )

        # Conservative: treat probe failure as "might be dirty" — skip cleanup.
        true
    end
  end

  defp worktree_ahead_of_base?(path, _task_id) do
    # `Worktree.has_commits_ahead?/2` already swallows git errors and
    # returns {:ok, true} as the conservative default, so we only need
    # to handle the OK shape here.
    case Worktree.has_commits_ahead?(path, "main") do
      {:ok, ahead?} -> ahead?
    end
  end
end
