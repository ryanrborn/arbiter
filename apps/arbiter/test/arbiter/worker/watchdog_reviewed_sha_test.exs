defmodule Arbiter.Worker.WatchdogReviewedShaTest do
  @moduledoc """
  bd-6bg54c / #1573 — what the Watchdog does when the head has moved past the
  reviewed commit.

  Separate from `Arbiter.Worker.WatchdogTest` because every case here needs the
  task's `last_reviewed_sha` to be readable from the DB by the Watchdog's own
  process: the whole point of the fix is that a `:stale_reviewed_sha` re-reads
  the recorded stamp instead of trusting a value memoised polls ago. That needs
  a shared (non-async) sandbox, which `Arbiter.DataCase` gives us.
  """
  # async: false — the sandbox is shared with the Watchdog GenServer's process,
  # and the StubMerger / StubAutoResumeDispatcher Agents are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  # The net diff the reviewer approved.
  @reviewed_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # The SAME net change, as it reads after main was merged into the branch:
  # hunk offsets shift and git recomputes the blob hashes, but not one content
  # line differs.
  @merge_from_main_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # A merge that resolved a conflict by writing NEW content: the net diff now
  # carries a line no reviewer approved.
  @conflict_resolved_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,8 @@ defmodule A do
     def run do
       :ok
  +    :extra
  +    :resolved_by_hand
     end
   end
  """

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    :ok
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp workspace do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "rs#{System.unique_integer([:positive])}"
    })
  end

  # A persisted task plus a :running worker attached to it.
  defp running_task(attrs) do
    ws = workspace()

    task =
      Ash.create!(
        Issue,
        Map.merge(
          %{title: "reviewed-sha guard", description: "body", workspace_id: ws.id},
          attrs
        )
      )

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)

    {pid, task, ws}
  end

  defp start_watchdog(worker_pid, task_id, mr_ref, ws, opts) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
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

  # ---- AC1 (Cause B): the re-review's stamp wins ---------------------------

  describe "a newer reviewed SHA recorded on the task (Cause B)" do
    test "is re-read on a stale head and the merge goes through on the new head" do
      # The round-2 APPROVE already stamped sha-2 on the task. This Watchdog
      # was started back when sha-1 was the reviewed head and memoised it —
      # which on a via_review_gate lane it would hold forever, because the
      # effective outcome never lapses from :approved.
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-2"})

      StubMerger.queue_get("!rsha1", [
        %{status: :open, approved: true, head_sha: "sha-2", base_ref: "main"}
      ])

      start_watchdog(pid, task.id, "!rsha1", ws, last_reviewed_sha: "sha-1")

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert StubMerger.last_merge() == {"!rsha1", "sha-2"},
             "the merge must be pinned to the head the round-2 reviewer approved"

      assert StubAutoResumeDispatcher.resume_count() == 0
    end
  end

  # ---- AC2: merge-from-main is still reviewed ------------------------------

  describe "a head that only merged the base branch in" do
    test "merges, pinned to the new head, when the net diff is unchanged" do
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-reviewed"})

      StubMerger.set_diff("!rsha2", "sha-reviewed", @reviewed_diff)
      StubMerger.set_diff("!rsha2", "sha-merged", @merge_from_main_diff)

      StubMerger.queue_get("!rsha2", [
        %{status: :open, approved: true, head_sha: "sha-merged", base_ref: "main"}
      ])

      start_watchdog(pid, task.id, "!rsha2", ws, last_reviewed_sha: "sha-reviewed")

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert StubMerger.last_merge() == {"!rsha2", "sha-merged"}
      assert StubAutoResumeDispatcher.resume_count() == 0

      # Both sides were compared against the MR's real base branch.
      calls = StubMerger.diff_calls()
      assert {"!rsha2", "main", "sha-reviewed"} in calls
      assert {"!rsha2", "main", "sha-merged"} in calls
    end

    test "does NOT merge when the merge resolved a conflict with new content" do
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-reviewed"})

      StubMerger.set_diff("!rsha3", "sha-reviewed", @reviewed_diff)
      StubMerger.set_diff("!rsha3", "sha-resolved", @conflict_resolved_diff)

      StubMerger.queue_get("!rsha3", [
        %{status: :open, approved: true, head_sha: "sha-resolved", base_ref: "main"}
      ])

      start_watchdog(pid, task.id, "!rsha3", ws, last_reviewed_sha: "sha-reviewed")

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)

      assert StubMerger.merge_count("!rsha3") == 0,
             "a conflict resolution writes content no reviewer saw — it must go back to review"
    end

    test "does NOT merge when the diffs cannot be read at all (fails closed)" do
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-reviewed"})

      # No diffs registered: the stub answers "" for both, which is not
      # evidence of equivalence.
      StubMerger.queue_get("!rsha4", [
        %{status: :open, approved: true, head_sha: "sha-unknown", base_ref: "main"}
      ])

      start_watchdog(pid, task.id, "!rsha4", ws, last_reviewed_sha: "sha-reviewed")

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
      assert StubMerger.merge_count("!rsha4") == 0
    end
  end

  # ---- AC3: authored content goes back to review ---------------------------

  describe "a head that advanced with authored content (Cause A)" do
    test "is routed back for a review round instead of retried forever" do
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-reviewed"})

      StubMerger.set_diff("!rsha5", "sha-reviewed", @reviewed_diff)
      StubMerger.set_diff("!rsha5", "sha-fixpass", @conflict_resolved_diff)

      StubMerger.queue_get("!rsha5", [
        %{status: :open, approved: true, head_sha: "sha-fixpass", base_ref: "main"}
      ])

      wpid = start_watchdog(pid, task.id, "!rsha5", ws, last_reviewed_sha: "sha-reviewed")
      ref = Process.monitor(wpid)

      # The merge loop is TERMINAL on a stale head: the Watchdog stops rather
      # than re-attempting the merge ~1/min forever (303+ attempts observed in
      # the incident).
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 2_000

      assert StubMerger.merge_count("!rsha5") == 0
      assert [args] = StubAutoResumeDispatcher.resumes()
      assert args.task_id == task.id
      assert args.mr_ref == "!rsha5"

      # One poll's worth of forge traffic, not an unbounded retry storm.
      assert StubMerger.get_count("!rsha5") <= 2
    end
  end

  # ---- AC4: escalate exactly once when neither path applies ----------------

  describe "when neither a re-review nor a review round is possible" do
    test "escalates exactly once and stops" do
      {pid, task, ws} = running_task(%{last_reviewed_sha: "sha-reviewed"})

      StubMerger.queue_get("!rsha6", [
        %{status: :open, approved: true, head_sha: "sha-foreign", base_ref: "main"}
      ])

      wpid =
        start_watchdog(pid, task.id, "!rsha6", ws,
          last_reviewed_sha: "sha-reviewed",
          # No auto-resume budget: there is no path back to review.
          max_auto_resumes: 0
        )

      ref = Process.monitor(wpid)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 2_000

      assert StubMerger.merge_count("!rsha6") == 0
      assert StubAutoResumeDispatcher.resume_count() == 0

      escalations = StubAutoResumeDispatcher.escalations()

      assert length(escalations) == 1,
             "the stale-SHA stall must page the coordinator ONCE, not every 30 polls forever"

      assert [{task_id, _ws, "!rsha6", _attempts, reason}] = escalations
      assert task_id == task.id
      assert {:stale_reviewed_sha, "sha-reviewed", "sha-foreign"} = reason

      # And it stays at one: the Watchdog is gone, so nothing re-pages.
      Process.sleep(60)
      assert length(StubAutoResumeDispatcher.escalations()) == 1
    end
  end
end
