defmodule Arbiter.Worker.ReviewOnlyWatchdogTest do
  @moduledoc """
  Regression tests for bd-4ji58d, bd-btcyn6, bd-ddtbhb, bd-bs3z04, and
  bd-4u7a1m.

  When a coordinator dispatches a reviewer via `worker_review` / `arb worker
  review`, the resulting worker is tagged `review_only: true` and has no
  branch/worktree.

  After bd-4u7a1m (hosted-forge Watchdog path):

    * APPROVE on a hosted-forge workspace (GitHub/GitLab) with a pr_ref →
      reviewer parks at :awaiting_review, spawns a Watchdog against the
      existing PR. The Watchdog drives the merge and calls Worker.complete
      only after the PR lands on main. The Driver then closes the task.
      The task must NOT reach :closed while the PR is still open.
    * APPROVE on a :direct workspace (no hosted forge) → reviewer completes
      normally, Driver closes the task, MergeQueue receives the signal and
      closes the task without calling the forge merge API (bd-ddtbhb, bd-bs3z04).
    * REQUEST_CHANGES → reviewer worker fails (not completes) so the Driver
      does NOT close the task; it stays :in_progress for a fix-pass.
    * No verdict → same as REQUEST_CHANGES (fail, task stays :in_progress).
    * pr_ref absent → complete directly; Driver closes task.

  The full ReviewGate merge path (fleet-authored work: enter_review_gate →
  merge_branch) is a separate path. As of bd-dkwhbn it no longer forces a
  merge — it passes `via_review_gate: true` only, so the Watchdog's merge
  decision follows the workspace's `auto_merge` setting like any other lane.
  This module's `trigger_watchdog_on_approval` path (coordinator-dispatched
  review_only workers) mirrors that fix as of bd-38e34o: it also passes only
  `via_review_gate: true`, so a review_only APPROVE never bypasses a
  human-merge (`auto_merge: false`) workspace policy.

  bd-btcyn6 regression: a reviewer that submits the review verdict via the
  tracker CLI (`gh pr review`) and also emits the required `VERDICT:` sentinel
  before `arb done` must land in a clean terminal state — not failed/INCONCLUSIVE.
  The review prompt was updated to require the sentinel; these tests cover the
  adapter-submitted-verdict completion path.
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

  # A workspace with GitHub strategy and auto_merge enabled — triggers the
  # bd-4u7a1m hosted-forge Watchdog path in trigger_watchdog_on_approval.
  defp new_github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gh-ws-#{System.unique_integer([:positive])}",
        prefix: "gh",
        config: %{"merge" => %{"strategy" => "github", "auto_merge" => true}}
      })

    ws
  end

  # bd-38e34o: a GitHub workspace with a human-merge policy (auto_merge: false).
  # A review_only reviewer APPROVE must never bypass this policy.
  defp new_github_workspace_no_auto_merge do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gh-human-ws-#{System.unique_integer([:positive])}",
        prefix: "ghh",
        config: %{"merge" => %{"strategy" => "github", "auto_merge" => false}}
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
    test "completes the worker when the task has a pr_ref (reviewer never merges)" do
      # bd-ddtbhb: a coordinator-dispatched reviewer that APPROVEs must NOT
      # start a merging Watchdog, even when a pr_ref is recorded on the task.
      # The review was already posted to the forge; merging is the author's job.
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

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
      # No merge must have been attempted.
      assert StubMerger.merge_count("pr-42") == 0
    end

    test "completes the worker and does not merge even when Watchdog would fire" do
      # bd-ddtbhb: even with permissive Watchdog timing, APPROVE on a
      # coordinator-dispatched reviewer completes immediately without parking
      # at :awaiting_review or starting the Watchdog at all.
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-99"}, action: :update)

      pid =
        start_reviewer(task, ["VERDICT: APPROVE", "great work"], %{
          watchdog_initial_delay_ms: 0,
          watchdog_interval_ms: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end, 3_000)

      assert Worker.state(pid).status == :completed
      assert StubMerger.merge_count("pr-99") == 0
    end

    test "completes normally when the task has no pr_ref" do
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

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "rv/repo", workspace_id: ws.id, meta: meta)

      :ok = Worker.advance(pid, :claude)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
    end
  end

  # ---- bd-btcyn6 regression: adapter-submitted verdict completion path ------

  describe "adapter-submitted verdict (bd-btcyn6)" do
    test "APPROVE after posting gh pr review completes cleanly (not failed/INCONCLUSIVE)" do
      # Regression for bd-btcyn6 + bd-ddtbhb: a reviewer that posts the GitHub
      # review via `gh pr review --approve` AND emits the required `VERDICT:
      # APPROVE` sentinel must land in :completed, NOT :failed or INCONCLUSIVE.
      # (Previously expected :awaiting_review; after bd-ddtbhb the reviewer
      # completes directly without parking — it must not merge.)
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-200"}, action: :update)

      pid =
        start_reviewer(task, [
          "Reviewed PR #200 — all changes look good.",
          "Posted review via: gh pr review 200 --approve --body 'LGTM'",
          "VERDICT: APPROVE",
          "arb done"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
      assert StubMerger.merge_count("pr-200") == 0
    end

    test "REQUEST_CHANGES after posting gh pr review fails the worker (not INCONCLUSIVE)" do
      # Regression for bd-btcyn6: a reviewer that posts CHANGES_REQUESTED via
      # `gh pr review --request-changes` AND emits `VERDICT: REQUEST_CHANGES`
      # must fail the worker (leaving the task :in_progress for a fix-pass),
      # NOT land as INCONCLUSIVE. Previously it landed INCONCLUSIVE because no
      # VERDICT: sentinel was present in stdout.
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-201"}, action: :update)

      pid =
        start_reviewer(task, [
          "Found issues in PR #201:",
          "- [error] lib/foo.ex:10 nil guard missing",
          "Posted review via: gh pr review 201 --request-changes --body 'see comments'",
          "VERDICT: REQUEST_CHANGES",
          "- [error] lib/foo.ex:10 nil guard missing"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      snap = Worker.state(pid)
      assert snap.status == :failed
      assert StubMerger.merge_count("pr-201") == 0

      # The task should NOT have landed as INCONCLUSIVE — it should have
      # recorded the actual REQUEST_CHANGES verdict.
      assert {:ok, updated_task} = Ash.get(Arbiter.Tasks.Issue, task.id)
      refute String.contains?(updated_task.notes || "", "INCONCLUSIVE")
      assert String.contains?(updated_task.notes || "", "REQUEST_CHANGES")
    end
  end

  # ---- bd-cw3w9p: review_only tasks are long-lived engagements (ReviewPatrol) ----
  # bd-do82bt fixed a bug where the Driver never closed review tasks at all.
  # bd-cw3w9p changes the intended behavior: review_only tasks must NOT
  # auto-close after their first verdict — they stay :in_progress so ReviewPatrol
  # can keep engaging on subsequent commits. The Driver exits without closing.

  describe "review_only task stays :in_progress after verdict (bd-cw3w9p)" do
    test "APPROVE + no pr_ref: Driver exits without closing the task (long-lived engagement)" do
      # bd-cw3w9p: review_only tasks are long-lived ReviewPatrol engagements.
      # The Driver must NOT close the task when the worker completes — task stays
      # :in_progress so ReviewPatrol can re-dispatch on the next commit.
      ws = new_workspace()
      task = new_task(ws)

      worker_pid = start_reviewer(task, ["VERDICT: APPROVE", "looks good"])

      {:ok, driver_pid} =
        Arbiter.Worker.Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: "dummy-#{task.id}",
          machine_pid: self(),
          claude_driven: true,
          interval_ms: 5,
          max_ticks: 200
        )

      on_exit(fn -> if Process.alive?(driver_pid), do: GenServer.stop(driver_pid, :normal) end)

      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Driver exits normally (its job is done) but must NOT close the task.
      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 3_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end

    test "REQUEST_CHANGES: Driver leaves the task :in_progress for a fix-pass" do
      # Regression for bd-do82bt: REQUEST_CHANGES fails the worker (not completes),
      # so the Driver exits without closing the task. The task must stay :in_progress
      # so a fix-pass can be dispatched.
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-50"}, action: :update)

      worker_pid =
        start_reviewer(task, [
          "VERDICT: REQUEST_CHANGES",
          "- [high] lib/foo.ex:5 missing guard"
        ])

      {:ok, driver_pid} =
        Arbiter.Worker.Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: "dummy-#{task.id}",
          machine_pid: self(),
          claude_driven: true,
          interval_ms: 5,
          max_ticks: 200
        )

      on_exit(fn -> if Process.alive?(driver_pid), do: GenServer.stop(driver_pid, :normal) end)

      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Wait for the worker to fail.
      wait_until(fn -> Worker.state(worker_pid).status == :failed end)

      # Driver should exit after seeing :failed.
      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 3_000

      # Task must remain :in_progress for the fix-pass.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end
  end

  # ---- bd-btcyn6 fallback: adapter-derived verdict when VERDICT sentinel missing ----

  describe "adapter-derived verdict fallback (bd-btcyn6)" do
    test "APPROVE derived from adapter review when stdout has no VERDICT sentinel" do
      # Belt-and-suspenders for bd-btcyn6 + bd-ddtbhb: if the reviewer posts
      # `gh pr review --approve` but omits the VERDICT sentinel, the completion
      # path falls back to querying the adapter's PR review state and derives
      # APPROVE — then completes without merging (not INCONCLUSIVE, not
      # :awaiting_review).
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-300"}, action: :update)

      StubMerger.set_review_feedback("pr-300", %{
        changes_requested: false,
        latest_review_id: 42,
        feedback: [%{kind: :review, state: "APPROVED", body: "LGTM", author: "bot"}]
      })

      # Stdout has no VERDICT sentinel — only the gh pr review output.
      pid =
        start_reviewer(task, [
          "Reviewed PR #300.",
          "Posted review via: gh pr review 300 --approve --body 'LGTM'"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
      assert StubMerger.merge_count("pr-300") == 0
    end

    test "REQUEST_CHANGES derived from adapter review when stdout has no VERDICT sentinel" do
      # Belt-and-suspenders for bd-btcyn6: if the reviewer posts
      # `gh pr review --request-changes` but omits the VERDICT sentinel,
      # the fallback derives REQUEST_CHANGES from the adapter and fails the
      # worker correctly — not INCONCLUSIVE.
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-301"}, action: :update)

      StubMerger.set_review_feedback("pr-301", %{
        changes_requested: true,
        latest_review_id: 43,
        feedback: [
          %{kind: :review, state: "CHANGES_REQUESTED", body: "nil guard missing", author: "bot"}
        ]
      })

      pid =
        start_reviewer(task, [
          "Found issues in PR #301.",
          "Posted review via: gh pr review 301 --request-changes --body 'see comments'"
        ])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      snap = Worker.state(pid)
      assert snap.status == :failed
      assert StubMerger.merge_count("pr-301") == 0

      assert {:ok, updated_task} = Ash.get(Arbiter.Tasks.Issue, task.id)
      refute String.contains?(updated_task.notes || "", "INCONCLUSIVE")
      assert String.contains?(updated_task.notes || "", "REQUEST_CHANGES")
    end

    test "still lands INCONCLUSIVE when stdout has no VERDICT and adapter has no review" do
      # When the reviewer never posted a review at all (no VERDICT sentinel,
      # no adapter review), INCONCLUSIVE is the correct outcome.
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-302"}, action: :update)

      # StubMerger returns empty feedback by default — no reviews submitted.
      pid = start_reviewer(task, ["Starting review of PR #302..."])

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :failed end)

      snap = Worker.state(pid)
      assert snap.status == :failed
      assert StubMerger.merge_count("pr-302") == 0
    end
  end

  # ---- bd-ddtbhb / bd-bs3z04 / bd-cw3w9p: coordinator reviewer with pr_ref ----
  # bd-bs3z04 established that APPROVE with a pr_ref signals MergeQueue for direct
  # workspaces. bd-cw3w9p supersedes that auto-close path: review_only tasks are
  # long-lived engagements and must NOT be closed by the MergeQueue signal either.
  # The forge merge count still stays 0 (bd-ddtbhb guarantee holds).

  describe "APPROVE + pr_ref: task stays open, PR not merged by forge (bd-ddtbhb, bd-cw3w9p)" do
    test "APPROVE with pr_ref: task stays :in_progress, PR not merged (direct workspace)" do
      # bd-cw3w9p: review_only tasks are long-lived ReviewPatrol engagements.
      # After an APPROVE verdict, neither the Driver nor the MergeQueue should
      # close the task. The forge merge count stays 0 (bd-ddtbhb still holds).
      ws = new_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-400"}, action: :update)

      worker_pid = start_reviewer(task, ["VERDICT: APPROVE", "LGTM"])

      {:ok, driver_pid} =
        Arbiter.Worker.Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: "dummy-#{task.id}",
          machine_pid: self(),
          claude_driven: true,
          interval_ms: 5,
          max_ticks: 200
        )

      on_exit(fn -> if Process.alive?(driver_pid), do: GenServer.stop(driver_pid, :normal) end)

      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Driver exits normally but must NOT close the task.
      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 3_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress

      # :direct strategy never calls the forge merge API.
      assert StubMerger.merge_count("pr-400") == 0
    end
  end

  # ---- bd-4u7a1m regression: hosted-forge Watchdog path ----------------------
  #
  # APPROVE on a GitHub/GitLab workspace with a pr_ref must NOT call complete_now
  # immediately. Instead the worker parks at :awaiting_review while a Watchdog
  # polls the forge and merges the PR, then calls Worker.complete. The Driver only
  # closes the task after the merge lands — preventing the premature close that
  # left bd-3u1au5 closed with PR #591 open.

  describe "APPROVE on hosted-forge workspace spawns Watchdog (bd-4u7a1m)" do
    test "worker parks at :awaiting_review, NOT :completed, while Watchdog waits for merge" do
      # Regression for bd-4u7a1m. The previous implementation called complete_now
      # before signaling MergeQueue, racing the Driver to close the task. Verify
      # the worker stays :awaiting_review (not :completed) while the Watchdog polls.
      ws = new_github_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-501"}, action: :update)

      pid =
        start_reviewer(task, ["VERDICT: APPROVE", "LGTM"], %{
          merger_workspace_override: ws,
          # Large delays so the Watchdog does not fire during this assertion.
          watchdog_initial_delay_ms: 5_000_000,
          watchdog_interval_ms: 5_000_000
        })

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :awaiting_review end)

      assert Worker.state(pid).status == :awaiting_review

      # Task must NOT be :closed while the PR is still open.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end

    test "Watchdog merges PR then Worker.complete fires, Driver exits without closing task (bd-cw3w9p)" do
      # bd-cw3w9p: review_only tasks are long-lived engagements. Even after the
      # Watchdog drives the PR merge and Worker.complete fires, the Driver must NOT
      # close the task — it stays :in_progress for ReviewPatrol to manage.
      # The Watchdog still drives the actual merge (bd-4u7a1m guarantee holds).
      ws = new_github_workspace()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-500"}, action: :update)

      # StubMerger.get default: {status: :open, approved: false} — Watchdog sees
      # :pending → effective_outcome(via_review_gate: true) → :approved →
      # workspace auto_merge: true → StubMerger.merge("pr-500") → :ok → complete.
      worker_pid =
        start_reviewer(task, ["VERDICT: APPROVE", "LGTM"], %{
          merger_workspace_override: ws,
          watchdog_initial_delay_ms: 0,
          watchdog_interval_ms: 50
        })

      {:ok, driver_pid} =
        Arbiter.Worker.Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: "dummy-#{task.id}",
          machine_pid: self(),
          claude_driven: true,
          interval_ms: 5,
          max_ticks: 400
        )

      on_exit(fn -> if Process.alive?(driver_pid), do: GenServer.stop(driver_pid, :normal) end)

      # Monitor before sending so we never miss the :DOWN.
      ref = Process.monitor(driver_pid)

      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Watchdog must drive a merge; Driver then exits. Task stays :in_progress.
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000

      assert StubMerger.merge_count("pr-500") >= 1

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end

    test "auto_merge:false workspace: APPROVE parks the Watchdog but does NOT merge (bd-38e34o)" do
      # Regression for bd-38e34o, mirroring bd-dkwhbn: trigger_watchdog_on_approval
      # (the coordinator-dispatched review_only APPROVE path) must not force a
      # merge via `force_merge: true`. On a human-merge (auto_merge: false)
      # hosted-forge workspace, the Watchdog must park the PR open, not merge it.
      ws = new_github_workspace_no_auto_merge()
      task = new_task(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "pr-600"}, action: :update)

      worker_pid =
        start_reviewer(task, ["VERDICT: APPROVE", "LGTM"], %{
          merger_workspace_override: ws,
          watchdog_initial_delay_ms: 0,
          watchdog_interval_ms: 50
        })

      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Give the Watchdog a few polling cycles to (incorrectly) merge, if it
      # were going to.
      Process.sleep(300)

      assert StubMerger.merge_count("pr-600") == 0

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress

      if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal)
    end

    test "no Watchdog spawned and complete_now used when task has no pr_ref (github workspace)" do
      # Even on a GitHub workspace, when no pr_ref is recorded there is nothing
      # to merge — complete directly. Task stays :in_progress (bd-cw3w9p).
      ws = new_github_workspace()
      task = new_task(ws)

      pid =
        start_reviewer(task, ["VERDICT: APPROVE", "reviewed"], %{
          merger_workspace_override: ws
        })

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert Worker.state(pid).status == :completed
    end
  end
end
