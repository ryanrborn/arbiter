defmodule Arbiter.Worker.StopRedispatchTest do
  @moduledoc """
  Regression tests for bd-cgmidt: `worker_stop` followed by an immediate
  re-`worker_dispatch` must not leave a live worker attached to a `:closed`
  task (the 2026-07-08 verus-client#3266 / lt-c9td4r orphan).

  Root cause: `Dispatch.dispatch/2` guards `:closed` only ONCE, at the front of
  the pipeline (`ensure_not_closed/1`), then transitions to `:in_progress`,
  provisions a worktree, and starts the worker. An asynchronous close landing
  inside that window — in production the MergeQueue direct-strategy close of an
  in-flight `{:worker_done}` from the just-stopped run — flips the bead to
  `:closed` AFTER the front guard passed but BEFORE the new worker is attached.
  The close's own `StopWorker` after-action finds no live worker to stop (the
  old one was already torn down by `worker_stop`, the new one not yet started),
  so the freshly-started worker is orphaned on a `:closed` task.

  The invariant under test: when `dispatch/2` returns `{:ok, _}` with a live
  worker, the task is NEVER `:closed`; a bead that raced to `:closed` inside the
  dispatch window is atomically reopened so the live worker is realigned, never
  orphaned. And `worker_stop` (teardown) never closes the bead.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "stop-redispatch-ws", prefix: "sr"})
    {:ok, ws: ws}
  end

  describe "worker_stop is teardown-only (bd-cgmidt Guard 1)" do
    test "stopping a task's worker never transitions the bead to :closed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "stop teardown", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress

      :ok = Worker.stop(task.id, :normal)
      wait_until(fn -> Worker.whereis(task.id) == nil end)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed
      assert reloaded.status == :in_progress
    end
  end

  describe "dispatch never orphans a live worker on a :closed task (bd-cgmidt Guard 2)" do
    # Reproduces the 18:47:43 → 18:47:44 sequence directly: the bead is already
    # `:closed` (a racing close landed and its StopWorker found no worker) at the
    # instant a live worker is attached. The dispatch reconciler must realign the
    # task to `:in_progress` rather than leave the worker orphaned on `:closed`.
    test "a bead that raced to :closed while the worker started is reopened + realigned",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "orphan race", workspace_id: ws.id})

      # The async close (e.g. MergeQueue direct worker_done) already fired.
      {:ok, _closed} = Ash.update(task, %{}, action: :close)
      {:ok, closed} = Ash.get(Issue, task.id)
      assert closed.status == :closed

      # The re-dispatch's start_worker attaches a fresh, live worker (18:47:44).
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(pid, :normal) end)

      assert {:ok, aligned} = Dispatch.realign_task_if_orphaned(task.id, pid)
      assert aligned.status == :in_progress

      # The live worker is preserved (never a wasted teardown), and the bead is
      # realigned so no live worker sits on a `:closed` task.
      assert Process.alive?(pid)
      {:ok, final} = Ash.get(Issue, task.id)
      assert final.status == :in_progress
    end

    test "reconciler is a no-op when the task is still :in_progress (happy path)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no race", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{status: :in_progress}, action: :update)

      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(pid, :normal) end)

      assert {:ok, aligned} = Dispatch.realign_task_if_orphaned(task.id, pid)
      assert aligned.status == :in_progress
      assert Process.alive?(pid)
    end
  end

  describe "worker_stop → worker_dispatch operator recovery (bd-cgmidt regression)" do
    test "ends :in_progress with exactly one live worker and was never closed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "stop then redispatch", workspace_id: ws.id})

      {:ok, first} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      first_pid = first.worker_pid
      assert first.task.status == :in_progress

      # Operator tears down the zombie worker.
      :ok = Worker.stop(task.id, :normal)
      wait_until(fn -> Worker.whereis(task.id) == nil end)

      {:ok, after_stop} = Ash.get(Issue, task.id)
      refute after_stop.status == :closed

      # Operator re-dispatches the same task.
      {:ok, second} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      assert second.task.status == :in_progress
      assert Process.alive?(second.worker_pid)
      assert second.worker_pid != first_pid
      # Exactly one live worker is registered for the task.
      assert Worker.whereis(task.id) == second.worker_pid

      {:ok, final} = Ash.get(Issue, task.id)
      assert final.status == :in_progress
      refute final.status == :closed
    end
  end
end
