defmodule Arbiter.Worker.MissingWorktreeTest do
  @moduledoc """
  Regression tests for bd-7pe74i: a worker that fails to start / never
  provisions a worktree must NOT close its bead (silent task loss).

  Two failure modes are exercised:

    1. **Worktree-provision failure** — a reviewable code directive
       (`issue_type: :feature`) signals `arb done` with no per-task branch in
       meta (the worktree was never provisioned). The old behaviour completed
       the worker, broadcast `{:worker_done}`, and let the MergeQueue close the
       bead as `:done` on enqueue (the `:direct` path). The fix refuses:
       fail + escalate, leave the bead open, and never broadcast `{:worker_done}`.

    2. **Early agent failure** — the agent subprocess crashes (non-zero exit,
       the `{:claude_failed, N, ""}` shape) before producing any deliverable.
       The worker fails + escalates via the stop-reason path and the bead stays
       open. It must never be closed and never broadcast `{:worker_done}`.

  The invariant under test: a bead only reaches `:closed` via a real completion
  (merged PR) or an explicit human/finalizer close — NEVER from a
  worker-failure / teardown path.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

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

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "missing-worktree-ws-#{System.unique_integer([:positive])}",
        prefix: "mw",
        config: %{}
      })

    %{ws: ws}
  end

  defp new_task(ws, issue_type) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "code directive",
        workspace_id: ws.id,
        issue_type: issue_type
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  describe "worktree-provision failure" do
    test "arb-done on a code directive with no branch fails + escalates instead of closing",
         %{ws: ws} do
      task = new_task(ws, :feature)

      # No {:worker_done} must ever be broadcast — that is the signal that would
      # let the MergeQueue close the bead.
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws.id)

      # Dispatch stamps :issue_type into meta. Critically there is NO :branch —
      # the worktree was never provisioned (the exact bd-3qcd8y shape:
      # worktree_path: null but the worker still runs).
      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{issue_type: :feature}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)

      # Must NOT have completed or routed to any review/merge path.
      refute snap.status == :completed
      refute snap.status == :awaiting_review_gate
      refute snap.status == :awaiting_review

      # The synthetic stop reason names the missing worktree.
      assert snap.meta.stop_reason.category == :missing_worktree
      assert snap.meta.failure_reason =~ "no per-task branch"

      # The bead stays open — never silently closed.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed

      # No {:worker_done} broadcast → the MergeQueue never enqueues → the
      # :direct-strategy immediate close can never fire.
      refute_receive {:worker_done, _}, 200

      # The Coordinator gets an addressed escalation naming the failure.
      escalations = Message.inbox("coordinator", workspace_id: ws.id)

      escalation =
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "no worktree provisioned"
    end

    test "review-only worker with no branch is NOT treated as a missing worktree",
         %{ws: ws} do
      # A review_only worker legitimately has no worktree/branch; it must route
      # through the reviewer-completion path, not the missing-worktree guard.
      task = new_task(ws, :feature)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{issue_type: :feature, review_only: true}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      # It reaches a terminal/parked state without the missing_worktree reason.
      wait_until(fn ->
        Worker.state(pid).status in [:failed, :completed, :awaiting_review, :awaiting_review_gate]
      end)

      snap = Worker.state(pid)
      refute match?(%{stop_reason: %{category: :missing_worktree}}, snap.meta)
    end
  end

  describe "early agent failure (claude_failed)" do
    test "a crashing agent subprocess fails + escalates and leaves the bead open",
         %{ws: ws} do
      task = new_task(ws, :feature)

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws.id)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{issue_type: :feature}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      # Drive a REAL session port that exits non-zero immediately with no
      # output — the {:claude_failed, 7, ""} early-agent-failure shape. The port
      # exit (not a synthetic done) routes the worker through the stop check,
      # which classifies a non-recoverable crash and fails + escalates.
      cwd = tmp_dir!("claude-crash")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "exit 7"]
        )

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      refute snap.status == :completed

      # The bead stays open — a failed start never closes it.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed

      # No {:worker_done} broadcast on a failed start.
      refute_receive {:worker_done, _}, 200

      # The Coordinator gets an addressed escalation for the stopped worker.
      escalations = Message.inbox("coordinator", workspace_id: ws.id)

      assert Enum.any?(
               escalations,
               &(&1.kind == :escalation and &1.directive_ref == task.id)
             )
    end
  end
end
