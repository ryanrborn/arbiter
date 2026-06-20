defmodule Arbiter.Worker.ReviewOnlyWatchdogTest do
  @moduledoc """
  Regression tests for bd-4ji58d.

  When a coordinator dispatches a reviewer via `worker_review` / `arb worker
  review`, the resulting worker is tagged `review_only: true` and has no
  branch/worktree. Before this fix, any verdict (APPROVE or REQUEST_CHANGES)
  caused the reviewer worker to complete normally, which prompted the Driver
  to close the task — without ever merging the PR.

  After the fix:

    * APPROVE → reviewer worker parks at :awaiting_review and the Watchdog
      merges the task's pr_ref automatically (via_review_gate: true path).
    * REQUEST_CHANGES → reviewer worker fails (not completes) so the Driver
      does NOT close the task; it stays :in_progress for a fix-pass.
    * No verdict → same as REQUEST_CHANGES (fail, task stays :in_progress).
    * No pr_ref on the task → APPROVE falls through to complete normally
      (nothing to merge).
  """

  # async: false — shares the singleton Worker registry/supervisor + the
  # named StubMerger Agent.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  defp new_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "reviewer-ws-#{System.unique_integer([:positive])}",
        prefix: "rv",
        config: %{}
      })

    ws
  end

  defp new_task(ws, opts \\ %{}) do
    {:ok, task} =
      Ash.create(Issue, Map.merge(%{title: "review-only task", workspace_id: ws.id}, opts))

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # Start a review_only worker with no branch (coordinator-dispatch path).
  # `output_lines` is injected directly into meta to simulate what the reviewer
  # worker would have printed before "arb done" — avoids spawning a real
  # subprocess or going through ClaudeSession.
  defp start_reviewer(task, output_lines, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          review_only: true,
          output_lines: output_lines,
          merger_adapter_override: StubMerger,
          merger_workspace_override: nil,
          # Park the Watchdog far in the future so it doesn't auto-poll during
          # status assertions. Tests that want to see the merge drive the
          # Watchdog manually via StubMerger.
          watchdog_initial_delay_ms: 5_000_000,
          watchdog_interval_ms: 5_000_000
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "rv/repo", workspace_id: task.workspace_id, meta: meta)

    :ok = Worker.advance(pid, :claude)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  # ---- APPROVE path ----------------------------------------------------------

  describe "APPROVE verdict" do
    test "parks at :awaiting_review with the task's pr_ref when APPROVE is detected" do
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-42"}, action: :update)

      pid =
        start_reviewer(task, [
          "reviewing the diff...",
          "VERDICT: APPROVE",
          "looks good, ship it"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :awaiting_review end)

      snap = Worker.state(pid)
      assert snap.status == :awaiting_review
      assert snap.mr_ref == "pr-42"
    end

    test "Watchdog auto-merges and completes the worker when the PR is approved" do
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-99"}, action: :update)

      # Queue: first poll returns approved, second returns merged.
      StubMerger.queue_get("pr-99", [
        %{status: :open, approved: true},
        %{status: :merged}
      ])

      pid =
        start_reviewer(task, ["VERDICT: APPROVE", "great work"], %{
          # Let the Watchdog poll immediately so the merge fires without sleeping.
          watchdog_initial_delay_ms: 0,
          watchdog_interval_ms: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end, 3_000)

      snap = Worker.state(pid)
      assert snap.status == :completed
      assert snap.mr_ref == "pr-99"
      # Watchdog's via_review_gate path calls merge on the first approved poll.
      assert StubMerger.merge_count("pr-99") >= 1
    end

    test "completes normally when the task has no pr_ref (nothing to merge)" do
      ws = new_workspace()
      task = new_task(ws)

      pid = start_reviewer(task, ["VERDICT: APPROVE", "reviewed"])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
    end
  end

  # ---- REQUEST_CHANGES path --------------------------------------------------

  describe "REQUEST_CHANGES verdict" do
    test "fails the worker (not completes) so the task stays :in_progress" do
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-77"}, action: :update)

      pid =
        start_reviewer(task, [
          "VERDICT: REQUEST_CHANGES",
          "- [high] lib/foo.ex:12 missing guard"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      snap = Worker.state(pid)
      assert snap.status == :failed
      # The PR must NOT have been merged.
      assert StubMerger.merge_count("pr-77") == 0
    end

    test "escalates findings to the Admiral mailbox" do
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-77"}, action: :update)

      pid =
        start_reviewer(task, [
          "VERDICT: REQUEST_CHANGES",
          "- [high] lib/foo.ex:12 missing nil guard"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      # An escalation message should have been posted to the Admiral mailbox.
      messages = Message.inbox("admiral", workspace_id: ws.id)

      assert Enum.any?(messages, fn m ->
               m.kind == :escalation and m.directive_ref == task.id
             end),
             "expected an Admiral escalation for task #{task.id}"
    end
  end

  # ---- no-verdict path -------------------------------------------------------

  describe "no parseable verdict" do
    test "fails the worker when the reviewer emits no VERDICT line" do
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-55"}, action: :update)

      pid = start_reviewer(task, ["some output but no verdict line"])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      assert Worker.state(pid).status == :failed
      assert StubMerger.merge_count("pr-55") == 0
    end
  end

  # ---- non-review_only guard -------------------------------------------------

  describe "non-review_only worker with no branch" do
    test "still completes normally (existing behaviour is unchanged)" do
      ws = new_workspace()
      task = new_task(ws)

      # No review_only flag, no branch — should complete as before.
      meta = %{output_lines: ["VERDICT: APPROVE", "some work done"]}
      {:ok, pid} = Worker.start(task_id: task.id, repo: "rv/repo", workspace_id: ws.id, meta: meta)
      :ok = Worker.advance(pid, :claude)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
    end
  end
end
