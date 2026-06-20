defmodule Arbiter.Worker.WatchdogTest do
  # async: false — shares the singleton Worker registry/supervisor and the
  # named StubMerger Agent. Unique task_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger
  alias Arbiter.Test.StubFixPassDispatcher

  # Injectable conflict resolver for the Phase 2b auto-resolve tests (#354). The
  # Watchdog calls `resolve/1` + `escalate_unresolved/4` from its own process, so
  # results are routed back to the test via a per-task pid stashed in
  # :persistent_term (unique task ids keep cases isolated).
  defmodule StubConflictResolver do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    @doc """
    Arm the stub for `task_id`. Opts:
      * `:pid` — `:ephemeral` (default) returns a worker pid that dies at once
        (so the Watchdog re-evaluates and can retry), or `:persistent` returns
        the test pid (stays "in flight", so exactly one dispatch happens).
      * `:result` — `:ok` (default) or `{:error, reason}`.
    """
    def arm(task_id, test_pid, opts \\ []) when is_list(opts) do
      :persistent_term.put({__MODULE__, task_id}, {test_pid, opts})
    end

    defp lookup(task_id), do: :persistent_term.get({__MODULE__, task_id}, nil)

    @impl true
    def resolve(%{task_id: task_id} = args) do
      case lookup(task_id) do
        {pid, opts} ->
          send(pid, {:resolve_called, args})

          worker_pid =
            case Keyword.get(opts, :pid, :ephemeral) do
              :ephemeral -> spawn(fn -> :ok end)
              :persistent -> pid
              p when is_pid(p) -> p
            end

          case Keyword.get(opts, :result, :ok) do
            :ok -> {:ok, %{worker_pid: worker_pid, worktree_path: "/tmp/fake", branch: "feat/x"}}
            {:error, _} = err -> err
          end

        nil ->
          {:error, :no_stub_armed}
      end
    end

    @impl true
    def escalate_unresolved(task_id, ws_id, branch, reason) do
      case lookup(task_id) do
        {pid, _} -> send(pid, {:escalate_called, task_id, ws_id, branch, reason})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp new_task_id, do: "watchdog-test-#{System.unique_integer([:positive])}"

  # A :running worker the Watchdog can drive to a terminal state.
  defp running_worker do
    task_id = new_task_id()
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, task_id}
  end

  defp start_watchdog(worker_pid, task_id, mr_ref, opts) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: nil,
      interval_ms: 20,
      initial_delay_ms: 0
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> if Process.alive?(wpid), do: GenServer.stop(wpid, :normal) end)
    wpid
  end

  defp wait_until(fun, timeout \\ 1_000) do
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

  describe "classify/1" do
    test "merged wins, even if also approved" do
      assert Watchdog.classify(%{status: :merged}) == :merged
      assert Watchdog.classify(%{status: :merged, approved: true}) == :merged
    end

    test "closed is terminal-fail" do
      assert Watchdog.classify(%{status: :closed}) == :closed
    end

    test "approved (not merged) is :approved" do
      assert Watchdog.classify(%{status: :open, approved: true}) == :approved
    end

    test "everything else is :pending" do
      assert Watchdog.classify(%{status: :open, approved: false}) == :pending
      assert Watchdog.classify(%{}) == :pending
    end
  end

  describe "poll outcomes" do
    test "merged MR completes the worker and stops the watchdog" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!1", [%{status: :merged}])

      wpid = start_watchdog(pid, task_id, "!1", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "closed MR fails the worker with :mr_closed and stops the watchdog" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!2", [%{status: :closed}])

      wpid = start_watchdog(pid, task_id, "!2", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Worker.state(pid).status == :failed end)
      assert Worker.state(pid).meta.failure_reason == {:mr_closed, "!2"}
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "approved + auto_merge merges then completes" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!3", [%{status: :open, approved: true}])

      start_watchdog(pid, task_id, "!3", auto_merge: true)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert StubMerger.merge_count("!3") == 1
    end

    test "approved without auto_merge parks until a later poll sees merged" do
      {pid, task_id} = running_worker()
      # First poll: approved but not merged -> stay parked (no merge call).
      # Second poll: merged -> complete.
      StubMerger.queue_get("!4", [%{status: :open, approved: true}, %{status: :merged}])

      start_watchdog(pid, task_id, "!4", auto_merge: false)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert StubMerger.merge_count("!4") == 0
    end

    test "records the last merger status + checked timestamp on the worker" do
      {pid, task_id} = running_worker()
      # Stay pending so the watchdog keeps polling and we can observe the record.
      StubMerger.queue_get("!5", [%{status: :open, approved: false}])

      start_watchdog(pid, task_id, "!5", [])

      wait_until(fn ->
        meta = Worker.state(pid).meta
        status = Map.get(meta, :last_merger_status)

        is_map(status) and
          Map.get(status, :status) == :open and
          Map.get(status, :approved) == false and
          match?(%DateTime{}, Map.get(meta, :last_checked_at))
      end)
    end
  end

  describe "block_reason/1" do
    test "extracts the adapter's block reason, nil when absent" do
      assert Watchdog.block_reason(%{block_reason: :conflict}) == :conflict
      assert Watchdog.block_reason(%{status: :open}) == nil
      assert Watchdog.block_reason(%{block_reason: nil}) == nil
      assert Watchdog.block_reason(nil) == nil
    end
  end

  describe "effective_block_reason/1 (gated on approval, #354)" do
    test "an approved PR with a block reason reports it" do
      assert Watchdog.effective_block_reason(%{
               status: :open,
               approved: true,
               block_reason: :conflict
             }) ==
               :conflict
    end

    test "a not-yet-approved PR with a block reason reports nil (ordinary review window)" do
      # A PR awaiting its required review routinely classifies as blocked
      # (GitHub :needs_approval, GitLab not_approved). That is the normal
      # pre-approval state, not a merge failure — so the gate suppresses it.
      assert Watchdog.effective_block_reason(%{
               status: :open,
               approved: false,
               block_reason: :needs_approval
             }) == nil
    end

    test "an approved PR with no block reason reports nil" do
      assert Watchdog.effective_block_reason(%{status: :open, approved: true}) == nil
    end

    test "merged/closed PRs report nil regardless of any stale block reason" do
      assert Watchdog.effective_block_reason(%{status: :merged, block_reason: :conflict}) == nil
      assert Watchdog.effective_block_reason(%{status: :closed, block_reason: :conflict}) == nil
    end

    test "non-map input is nil" do
      assert Watchdog.effective_block_reason(nil) == nil
    end
  end

  describe "blocked-merge detection (#354)" do
    test "an approved :conflict records the reason, dispatches a rebase acolyte, and does not fail" do
      {pid, task_id} = running_worker()
      # An approved-but-conflicting PR. Phase 2b: the Warden records the reason
      # AND dispatches a rebase-resolve acolyte against the existing worktree
      # (rather than only parking). A :persistent stub stays "in flight" so this
      # is a single dispatch. The worker must NOT be failed.
      StubConflictResolver.arm(task_id, self(), pid: :persistent)

      StubMerger.queue_get("!b1", [
        %{status: :open, approved: true, block_reason: :conflict}
      ])

      start_watchdog(pid, task_id, "!b1",
        auto_merge: false,
        conflict_resolver: StubConflictResolver
      )

      assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000

      wait_until(fn ->
        status = Map.get(Worker.state(pid).meta, :last_merger_status)
        is_map(status) and Map.get(status, :block_reason) == :conflict
      end)

      # Auto-resolve must not fail the worker — it stays parked while the acolyte
      # rebases, and a single in-flight resolver is never escalated.
      refute Worker.state(pid).status == :failed
      refute_receive {:escalate_called, _, _, _, _}, 200
    end

    test "a clear block reason (nil) leaves the normal flow untouched" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!b2", [%{status: :merged, block_reason: nil}])

      start_watchdog(pid, task_id, "!b2", [])

      wait_until(fn -> Worker.state(pid).status == :completed end)
    end
  end

  describe "auto-resolve :behind_base (#354 Phase 2a)" do
    test "runs update-branch on an approved behind-base PR, then merges when caught up" do
      {pid, task_id} = running_worker()
      # Poll 1: approved but behind base -> the Warden runs update-branch.
      # Poll 2: caught up (no block) -> auto-merge fires.
      StubMerger.queue_get("!ar1", [
        %{status: :open, approved: true, block_reason: :behind_base},
        %{status: :open, approved: true}
      ])

      start_watchdog(pid, task_id, "!ar1", auto_merge: true)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert StubMerger.update_branch_count("!ar1") == 1
      assert StubMerger.merge_count("!ar1") == 1
    end

    test "stops retrying update-branch after max_auto_resolve_attempts and parks" do
      {pid, task_id} = running_worker()
      # Perpetually behind base: the Warden retries update-branch up to the cap,
      # then escalates + parks (no more update-branch calls).
      StubMerger.queue_get("!ar2", [%{status: :open, approved: true, block_reason: :behind_base}])

      start_watchdog(pid, task_id, "!ar2", auto_merge: true, max_auto_resolve_attempts: 2)

      wait_until(fn -> StubMerger.update_branch_count("!ar2") >= 2 end)
      # Let several more poll intervals elapse — the count must stay capped at 2.
      Process.sleep(120)
      assert StubMerger.update_branch_count("!ar2") == 2
      refute Worker.state(pid).status == :failed
    end

    test "a failed update-branch (conflict introduced) does not merge or fail the worker" do
      {pid, task_id} = running_worker()
      StubMerger.set_update_branch_result({:error, :merge_conflict})
      StubMerger.queue_get("!ar3", [%{status: :open, approved: true, block_reason: :behind_base}])

      start_watchdog(pid, task_id, "!ar3",
        auto_merge: true,
        max_auto_resolve_attempts: 2,
        interval_ms: 10
      )

      wait_until(fn -> StubMerger.update_branch_count("!ar3") >= 1 end)
      Process.sleep(80)
      # It attempted update-branch but, on failure, never merged or failed the worker.
      assert StubMerger.merge_count("!ar3") == 0
      refute Worker.state(pid).status == :failed
    end
  end

  describe "auto-resolve :ci_failed (#354 Phase 2a)" do
    test "dispatches a fix-pass acolyte briefed with the failing check logs" do
      {pid, task_id} = running_worker()
      StubMerger.set_failing_checks("!cf1", [%{name: "test", summary: "boom", url: nil}])
      StubMerger.queue_get("!cf1", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!cf1",
        auto_merge: true,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)

      args = StubFixPassDispatcher.last_args()
      assert args.task_id == task_id
      assert args.pr_ref == "!cf1"
      assert args.checks == [%{name: "test", summary: "boom", url: nil}]
    end

    test "stops re-dispatching the fix pass after max_auto_resolve_attempts" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!cf2", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!cf2",
        auto_merge: true,
        max_auto_resolve_attempts: 2,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 2 end)
      Process.sleep(120)
      assert StubFixPassDispatcher.call_count() == 2
    end
  end

  describe "Phase 2a leaves :conflict / :needs_approval unaffected (#354)" do
    test ":conflict never triggers update-branch or a fix pass" do
      {pid, task_id} = running_worker()
      # auto_merge: false keeps the worker parked so we can observe several polls.
      StubMerger.queue_get("!na1", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!na1",
        auto_merge: false,
        fix_pass_dispatcher: StubFixPassDispatcher
  describe "conflict auto-resolve (#354, Phase 2b)" do
    test "dispatches the rebase acolyte with the task id + mr ref" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :persistent)
      StubMerger.queue_get("!c1", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c1",
        auto_merge: false,
        conflict_resolver: StubConflictResolver
      )

      assert_receive {:resolve_called, args}, 1_000
      assert args.task_id == task_id
      assert args.pr_ref == "!c1"
    end

    test "after max_conflict_attempts rebase passes it escalates with the attempt count" do
      {pid, task_id} = running_worker()
      # :ephemeral resolver pids die at once, so each pass completes and the next
      # poll (still conflicting) spawns the next attempt until the cap is hit.
      StubConflictResolver.arm(task_id, self(), pid: :ephemeral)
      StubMerger.queue_get("!c2", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c2",
        auto_merge: false,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
      assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
      assert_receive {:escalate_called, ^task_id, _ws, _branch, reason}, 1_000
      assert reason =~ "exhausted"
      assert reason =~ "2 rebase attempt"
      # Escalation must not fail the worker — it stays parked for a human.
      refute Worker.state(pid).status == :failed
    end

    test "only dispatches max_conflict_attempts acolytes, not one per poll" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :ephemeral)
      StubMerger.queue_get("!c3", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c3",
        auto_merge: false,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      assert_receive {:resolve_called, _}, 1_000
      assert_receive {:resolve_called, _}, 1_000
      assert_receive {:escalate_called, _, _, _, _}, 1_000
      # Past the cap the Warden stays parked and must not keep spawning acolytes
      # or re-paging on every subsequent poll.
      refute_receive {:resolve_called, _}, 200
      refute_receive {:escalate_called, _, _, _, _}, 200
    end

    test "a cleared conflict resets the counter so it never escalates" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :ephemeral)
      # Conflict on the first poll, mergeable thereafter — the rebase cleared it.
      StubMerger.queue_get("!c4", [
        %{status: :open, approved: true, block_reason: :conflict},
        %{status: :open, approved: true}
      ])

      start_watchdog(pid, task_id, "!c4",
        auto_merge: false,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
      # Conflict cleared on the next poll → counter resets → no escalation ever.
      refute_receive {:escalate_called, _, _, _, _}, 300
    end

    test "a resolved conflict lets the next poll auto-merge (re-attempt merge)" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :ephemeral)
      # Conflict, then mergeable+approved — the resolver's force-push cleared it
      # and the Warden's next poll re-attempts (and lands) the merge.
      StubMerger.queue_get("!c5", [
        %{status: :open, approved: true, block_reason: :conflict},
        %{status: :open, approved: true}
      ])

      start_watchdog(pid, task_id, "!c5",
        auto_merge: true,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!c5") >= 1
    end

    test "auto_resolve_conflict: false falls back to the Phase 1 escalation (no dispatch)" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :persistent)
      StubMerger.queue_get("!c6", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c6",
        auto_merge: false,
        auto_resolve_conflict: false,
        conflict_resolver: StubConflictResolver
      )

      wait_until(fn ->
        status = Map.get(Worker.state(pid).meta, :last_merger_status)
        is_map(status) and Map.get(status, :block_reason) == :conflict
      end)

      # With auto-resolve off, no rebase acolyte is dispatched.
      refute_receive {:resolve_called, _}, 200
      refute Worker.state(pid).status == :failed
    end
  end

  describe "via_review_gate short-circuits forge approval (bd-66ey1o)" do
    test "treats :pending as :approved and force-auto-merges on first poll" do
      {pid, task_id} = running_worker()
      # No approval — pure :pending sequence — but via_review_gate must flip it
      # to :approved so the merge fires anyway.
      StubMerger.queue_get("!t1", [%{status: :open, approved: false}])

      start_watchdog(pid, task_id, "!t1", via_review_gate: true)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!t1") >= 1
    end

    test "via_review_gate still defers to :merged and :closed terminal status" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!t2", [%{status: :closed}])

      start_watchdog(pid, task_id, "!t2", via_review_gate: true)

      wait_until(fn -> Worker.state(pid).status == :failed end)
      assert Worker.state(pid).meta.failure_reason == {:mr_closed, "!t2"}
      # Importantly: we did NOT call merge/1 on a closed MR even though
      # via_review_gate was on. Approval overriding is for :pending only.
      assert StubMerger.merge_count("!t2") == 0
    end
  end

  describe "watchdog (bd-66ey1o / bd-akr4il)" do
    test "fails the worker after max_polls on auto_merge: true lanes" do
      {pid, task_id} = running_worker()
      # auto_merge ON: if the forge never auto-merges after cap polls something
      # is broken — fail loudly so the task surfaces in the notification feed.
      start_watchdog(pid, task_id, "!w1",
        interval_ms: 10,
        initial_delay_ms: 0,
        max_polls: 2,
        auto_merge: true
      )

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      assert Worker.state(pid).meta.failure_reason == {:awaiting_review_timeout, 2}
    end

    test "parks (does not fail) the worker after max_polls on auto_merge: false lanes" do
      {pid, task_id} = running_worker()
      # auto_merge OFF (human-merge): a reviewer may take hours or overnight.
      # Hitting the poll cap must NOT fail the task — the worker stays parked
      # at :awaiting_review and the Watchdog stops to free resources (bd-akr4il).
      wpid =
        start_watchdog(pid, task_id, "!w3",
          interval_ms: 10,
          initial_delay_ms: 0,
          max_polls: 2,
          auto_merge: false
        )

      wref = Process.monitor(wpid)

      # Watchdog stops without failing the worker.
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 2_000
      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end

    test "does not fire when via_review_gate: true (merge happens before cap)" do
      {pid, task_id} = running_worker()

      start_watchdog(pid, task_id, "!w2",
        via_review_gate: true,
        interval_ms: 10,
        initial_delay_ms: 0,
        max_polls: 2
      )

      wait_until(fn -> Worker.state(pid).status == :completed end)
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end
  end

  describe "pipeline watching (watch_pipeline: true)" do
    test "does not escalate when watch_pipeline is false (default)" do
      {pid, task_id} = running_worker()
      # Pipeline is :failed but watch_pipeline not set — worker should just
      # keep polling and eventually complete (not escalate or fail early).
      StubMerger.queue_get("!p1", [
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :merged}
      ])

      start_watchdog(pid, task_id, "!p1", [])

      wait_until(fn -> Worker.state(pid).status == :completed end)
      # The key assertion: with watch_pipeline off, a :failed pipeline must not
      # fail the worker — it should still complete when the MR merges.
      assert Worker.state(pid).status == :completed
    end

    test "stays parked when pipeline is :failed and watch_pipeline is true" do
      {pid, task_id} = running_worker()
      # First two polls: pipeline :failed, MR still open — should stay parked.
      # Third poll: MR merged — should complete.
      StubMerger.queue_get("!p2", [
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :merged}
      ])

      start_watchdog(pid, task_id, "!p2", watch_pipeline: true)

      # Wait until merged — the pipeline failure must not have failed the task.
      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).status == :completed
      assert Worker.state(pid).meta[:failure_reason] == nil
    end

    test "pipeline :success does not affect normal MR flow" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!p3", [%{status: :merged, pipeline: :success}])

      start_watchdog(pid, task_id, "!p3", watch_pipeline: true)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).status == :completed
    end
  end

  describe "lifecycle" do
    test "stops when the watched worker dies" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!6", [%{status: :open, approved: false}])

      wpid = start_watchdog(pid, task_id, "!6", [])
      ref = Process.monitor(wpid)

      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "init returns :ignore when the worker is already gone" do
      assert Watchdog.start_link(
               task_id: "gone",
               worker: "no-such-task",
               mr_ref: "!7",
               adapter: StubMerger
             ) == :ignore
    end

    # bd-91rnwq: DynamicSupervisor.start_child propagates :ignore from
    # Watchdog.init directly (not wrapped in {:error, ...}). The unhandled :ignore
    # in start_watchdog/3's case clause was the root cause of the CaseClauseError
    # that crashed the worker after a successful MR creation.
    test "start/1 via DynamicSupervisor returns :ignore when worker is already gone" do
      assert Watchdog.start(
               task_id: "gone-ds",
               worker: "no-such-task",
               mr_ref: "!ignore-ds",
               adapter: StubMerger,
               workspace: nil
             ) == :ignore
    end
  end

  describe "open_mr resilience (bd-91rnwq)" do
    test "Worker.open_mr/5 transitions to :awaiting_review on successful MR creation" do
      # Regression guard: open_mr must always reach :awaiting_review when
      # safe_open succeeds, regardless of what start_watchdog does internally.
      # Before the fix, a CaseClauseError in start_watchdog propagated uncaught
      # through handle_call and crashed the worker, orphaning the MR.
      {pid, _task_id} = running_worker()
      StubMerger.next_open_ref("!oom1")
      StubMerger.queue_get("!oom1", [%{status: :open, approved: false}])

      {:ok, mr_ref} =
        Worker.open_mr(pid, "feature/x", "Fix it", "", %{adapter: StubMerger, workspace: nil})

      assert mr_ref == "!oom1"
      assert Worker.state(pid).status == :awaiting_review
      assert Worker.state(pid).mr_ref == "!oom1"
    end
  end
end
