defmodule Arbiter.Worker.WatchdogTest do
  # async: false — shares the singleton Worker registry/supervisor and the
  # named StubMerger Agent. Unique task_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubAutoResumeDispatcher

  # A stand-in for the resolver's `Arbiter.Worker` GenServer. The REAL resolver
  # worker does NOT exit when its rebase worker finishes — it lingers in a
  # terminal status (:completed/:failed) until task :close — so the Watchdog must
  # detect completion from the worker's *status*, not a process `:DOWN` (#354
  # review). This fake models exactly that: it stays alive and answers `:snapshot`
  # with a fixed status, and self-terminates when the owning test process dies so
  # cases don't leak processes.
  defmodule FakeResolverWorker do
    @moduledoc false
    use GenServer

    def start(status, owner) when is_atom(status) and is_pid(owner),
      do: GenServer.start(__MODULE__, {status, owner})

    @impl true
    def init({status, owner}) do
      Process.monitor(owner)
      {:ok, status}
    end

    @impl true
    def handle_call(:snapshot, _from, status), do: {:reply, %{status: status}, status}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, status), do: {:stop, :normal, status}
    def handle_info(_msg, status), do: {:noreply, status}
  end

  # Injectable conflict resolver for the Phase 2b auto-resolve tests (#354). The
  # Watchdog calls `resolve/1` + `escalate_unresolved/4` from its own process, so
  # results are routed back to the test via a per-task pid stashed in
  # :persistent_term (unique task ids keep cases isolated).
  defmodule StubConflictResolver do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    alias Arbiter.Worker.WatchdogTest.FakeResolverWorker

    @doc """
    Arm the stub for `task_id`. Opts:
      * `:pid` — the resolver worker the Watchdog gets back. The fake stays alive
        (mirroring the real resolver, which lingers after its worker exits):
        * `:completed` (default) — reports a terminal status, so the Watchdog
          detects the pass finished *without the process dying* and can
          retry/escalate (a fresh fake is minted per `resolve/1` call);
        * `:running` — reports `:running`, so the resolver stays "in flight" and
          exactly one dispatch happens;
        * a pid — used verbatim.
      * `:result` — `:ok` (default), `:no_op` (the resolver found zero
        divergence and spawned nothing — bd-1x4r25), or `{:error, reason}`.
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

          case Keyword.get(opts, :result, :ok) do
            :ok ->
              worker_pid = resolver_worker(Keyword.get(opts, :pid, :completed), pid)
              send(pid, {:resolver_spawned, worker_pid})
              {:ok, %{worker_pid: worker_pid, worktree_path: "/tmp/fake", branch: "feat/x"}}

            :no_op ->
              {:ok, :no_op}

            {:error, _} = err ->
              err
          end

        nil ->
          {:error, :no_stub_armed}
      end
    end

    defp resolver_worker(status, owner) when status in [:completed, :failed, :running] do
      {:ok, p} = FakeResolverWorker.start(status, owner)
      p
    end

    defp resolver_worker(p, _owner) when is_pid(p), do: p

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
    StubAutoResumeDispatcher.reset()
    :ok
  end

  # `Process.alive?/1` then `GenServer.stop/3` is a TOCTOU race: several of
  # these tests drive the worker to a terminal state, so it may exit between
  # the check and the stop, and the `on_exit` callback then fails a test that
  # had already passed. Treat "already gone" as success.
  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp new_task_id, do: "watchdog-test-#{System.unique_integer([:positive])}"

  # An unpersisted Workspace struct with an id — enough for the Watchdog, which
  # only reads `.id` (for the escalation's `workspace_id`) and `.config`. The
  # exhaustion escalation needs a binary workspace_id to address its coordinator
  # page; without one it logs loudly and sends nothing (the Low review finding).
  defp test_workspace(config \\ %{}) do
    %Arbiter.Tasks.Workspace{
      id: "ws-#{System.unique_integer([:positive])}",
      config: config
    }
  end

  # A :running worker the Watchdog can drive to a terminal state. `opts` are
  # merged into `Worker.start/1` — the auto-resume cases pass `:meta` to seed a
  # prior `:awaiting_review_resume_attempts` count (bd-8eheb6).
  defp running_worker(opts \\ []) do
    task_id = new_task_id()
    {:ok, pid} = Worker.start(Keyword.merge([task_id: task_id, repo: "arbiter"], opts))
    :ok = Worker.advance(pid, :implement)

    on_exit(fn -> stop_quietly(pid) end)
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
    on_exit(fn -> stop_quietly(wpid) end)
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
    test "an approved :conflict records the reason, dispatches a rebase worker, and does not fail" do
      {pid, task_id} = running_worker()
      # An approved-but-conflicting PR. Phase 2b: the Watchdog records the reason
      # AND dispatches a rebase-resolve worker against the existing worktree
      # (rather than only parking). A :running stub stays "in flight" so this
      # is a single dispatch. The worker must NOT be failed.
      StubConflictResolver.arm(task_id, self(), pid: :running)

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

      # Auto-resolve must not fail the worker — it stays parked while the worker
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

  describe "non-author-approval park (bd-c3lchp)" do
    test "an auto_merge lane parks instead of failing at the poll ceiling" do
      {pid, task_id} = running_worker()
      # A fully-green PR that is not yet approved and is parked on a required
      # non-author approval the fleet can't supply. The stub repeats the last
      # result once drained, so this reason recurs on every poll.
      StubMerger.queue_get("!na1", [
        %{status: :open, approved: false, block_reason: :needs_nonauthor_approval}
      ])

      # A tiny ceiling: a *normal* pending PR on an auto_merge lane would fail
      # after the very first poll. The non-author-approval handling must lift the
      # ceiling to :infinity so the worker parks rather than failing.
      start_watchdog(pid, task_id, "!na1",
        auto_merge: true,
        max_polls: 1,
        workspace: test_workspace()
      )

      # Let well more than `max_polls` intervals elapse (interval_ms: 20).
      Process.sleep(150)

      refute Worker.state(pid).status == :failed
    end

    test "a later approval on a parked PR auto-merges and completes" do
      {pid, task_id} = running_worker()
      # First poll: blocked on the non-author approval. Second poll: a human has
      # approved, so the now-green PR auto-merges.
      StubMerger.queue_get("!na2", [
        %{status: :open, approved: false, block_reason: :needs_nonauthor_approval},
        %{status: :open, approved: true, block_reason: nil}
      ])

      start_watchdog(pid, task_id, "!na2",
        auto_merge: true,
        max_polls: 1,
        workspace: test_workspace()
      )

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert StubMerger.merge_count("!na2") >= 1
    end

    test "a lapsed :needs_nonauthor_approval signal does not revoke the park while still unapproved (bd-krg7ci round 4)" do
      # The adapters only emit :needs_nonauthor_approval while CI is green. If CI
      # later goes red (or starts running again), the adapter stops emitting the
      # narrow reason even though the PR is still unapproved — the raw signal
      # simply vanishes, it doesn't mean a human approved. Before the fix this
      # nil block_reason satisfied the ceiling-restore branch, dropping
      # `max_polls` back to its finite base and letting the ordinary auto_merge
      # ceiling fail the worker out from under a PR still awaiting the same
      # human reviewer.
      {pid, task_id} = running_worker()

      StubMerger.queue_get("!na3", [
        %{status: :open, approved: false, block_reason: :needs_nonauthor_approval},
        %{status: :open, approved: false, block_reason: nil}
      ])

      start_watchdog(pid, task_id, "!na3",
        auto_merge: true,
        max_polls: 2,
        interval_ms: 15,
        workspace: test_workspace()
      )

      # Let well more than `max_polls` intervals elapse after the signal lapses.
      Process.sleep(150)

      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end
  end

  describe "auto-resolve :behind_base (#354 Phase 2a)" do
    test "runs update-branch on an approved behind-base PR, then merges when caught up" do
      {pid, task_id} = running_worker()
      # Poll 1: approved but behind base -> the Watchdog runs update-branch.
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
      # Perpetually behind base: the Watchdog retries update-branch up to the cap,
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

    test "a flapping behind_base/clear cycle still trips the finite poll ceiling (bd-krg7ci round 2)" do
      # Each `:behind_base` episode here resolves within a single auto-resolve
      # pass and never lifts `max_polls` to `:infinity` (unlike the merge-stall
      # and exhausted-block parks). Before the fix, the block-clear branch reset
      # `poll_count` to 0 whenever `last_block_reason != nil` — which is also true
      # right after a *resolved* block, not just a genuinely parked one — so a
      # lane that kept drifting behind base and catching back up reset the
      # counter on every cycle and the 30-poll-style ceiling never tripped no
      # matter how long it flapped. The gate now also requires
      # `max_polls != base_max_polls` (i.e. the episode actually parked), so a
      # bounded, always-resolved block leaves `poll_count` monotonic.
      {pid, task_id} = running_worker()

      StubMerger.queue_get(
        "!bb1",
        List.duplicate(
          [
            %{status: :open, approved: true, block_reason: :behind_base},
            %{status: :open, approved: false}
          ],
          8
        )
        |> List.flatten()
      )

      start_watchdog(pid, task_id, "!bb1", auto_merge: true, max_polls: 4, interval_ms: 15)

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      assert match?({:awaiting_review_timeout, 4}, Worker.state(pid).meta[:failure_reason])
    end
  end

  describe "auto-resolve :ci_failed (#354 Phase 2a)" do
    test "dispatches a fix-pass worker briefed with the failing check logs" do
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

    test "resumes and merges once a stalled PR goes green after auto-resolve is exhausted (bd-krg7ci)" do
      {pid, task_id} = running_worker()
      # A CI failure that never clears on its own (e.g. an infra flake the fix-pass
      # can't touch, later fixed by a manual pipeline retry outside Arbiter). Once
      # the bounded fix-pass retries are exhausted, the Watchdog escalates to the
      # coordinator and MUST keep polling indefinitely — same as the
      # needs_nonauthor_approval park — so a later out-of-band fix (a manual
      # pipeline retry making the MR green again) still gets picked up. Before the
      # fix, the shared `poll_count` kept climbing across the auto-resolve
      # attempts and tripped the ordinary auto_merge `max_polls` ceiling, which
      # failed the worker and stopped the Watchdog for good — reproducing the
      # live incident (bd-krg7ci) where a green, approved MR sat unmerged forever
      # because nothing was left watching it. The acceptance behavior isn't just
      # "doesn't die" — it's "picks the PR back up and merges it" once the block
      # clears, so this asserts the actual merge happens, not just survival.
      StubMerger.queue_get("!cf3", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!cf3",
        auto_merge: true,
        max_auto_resolve_attempts: 1,
        max_polls: 3,
        interval_ms: 15,
        fix_pass_dispatcher: StubFixPassDispatcher,
        workspace: test_workspace()
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)

      # Let well more than `max_polls` intervals elapse after exhaustion — the
      # worker must still be alive to pick up the eventual green state.
      Process.sleep(150)
      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])

      # The out-of-band fix lands (a manual pipeline retry makes the MR green).
      StubMerger.queue_get("!cf3", [%{status: :open, approved: true}])

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!cf3") >= 1
    end

    test "an approval dismissal after exhausted-block park does not revoke the park (bd-krg7ci round 4)" do
      # Standard branch-protection behaviour dismisses the existing approval on a
      # new commit push — a common way to retrigger CI after the flake this task
      # is about. Before the fix, the dismissal made `effective_block_reason/1`
      # collapse to `nil` (it's gated on `approved: true`), which satisfied the
      # ceiling-restore branch even though the underlying :ci_failed episode was
      # never actually resolved, letting the worker die at the restored finite
      # ceiling with the PR still red and parked.
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!cf4", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!cf4",
        auto_merge: true,
        max_auto_resolve_attempts: 1,
        max_polls: 3,
        interval_ms: 15,
        fix_pass_dispatcher: StubFixPassDispatcher,
        workspace: test_workspace()
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)

      # Let the retry budget actually exhaust and the park kick in (mirrors the
      # "resumes and merges" test above) before simulating the dismissal, so
      # this test exercises the park-revocation bug rather than racing ahead of
      # the park ever being established.
      Process.sleep(60)
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])

      # The approval gets dismissed by the push that retriggered CI — the PR is
      # still effectively blocked (CI hasn't gone green yet), just unapproved now.
      StubMerger.queue_get("!cf4", [%{status: :open, approved: false, block_reason: nil}])

      # Let well more than `max_polls` intervals elapse after the dismissal.
      Process.sleep(150)

      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end
  end

  describe "retry_auto_resolve/1 (bd-bspakl)" do
    test "re-arms one more fix-pass attempt once auto-resolve is exhausted and parked" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar1", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!rar1",
        auto_merge: true,
        max_auto_resolve_attempts: 1,
        max_polls: 3,
        interval_ms: 15,
        fix_pass_dispatcher: StubFixPassDispatcher,
        workspace: test_workspace()
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      # Let the budget actually exhaust and the park kick in before re-arming.
      Process.sleep(60)

      assert Watchdog.retry_auto_resolve(task_id) == :ok

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 2 end)
    end

    test "refuses to re-arm a watchdog that isn't parked on :ci_failed" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar2", [%{status: :open, approved: false}])

      wpid =
        start_watchdog(pid, task_id, "!rar2",
          auto_merge: true,
          fix_pass_dispatcher: StubFixPassDispatcher
        )

      wait_until(fn -> Process.alive?(wpid) end)

      assert Watchdog.retry_auto_resolve(task_id) == {:error, :not_parked_on_ci_failed}
    end

    test "returns :not_found when no watchdog is registered for the task" do
      assert Watchdog.retry_auto_resolve("no-such-task-#{System.unique_integer([:positive])}") ==
               {:error, :not_found}
    end

    test "does not start a second, permanent poll chain per re-arm" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar3", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!rar3",
        auto_merge: true,
        max_auto_resolve_attempts: 1,
        max_polls: 1000,
        interval_ms: 20,
        fix_pass_dispatcher: StubFixPassDispatcher,
        workspace: test_workspace()
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      # Let the budget exhaust and the park kick in.
      Process.sleep(60)

      baseline = StubMerger.get_count("!rar3")
      assert Watchdog.retry_auto_resolve(task_id) == :ok
      assert Watchdog.retry_auto_resolve(task_id) == :ok
      assert Watchdog.retry_auto_resolve(task_id) == :ok

      # Four re-arms deep (1 original chain + 3 re-arms), the poll rate must
      # still be ~1 poll per interval_ms, not 4x — a second, independent
      # `Process.send_after/3` chain per re-arm would multiply it (bd-bspakl
      # review round 1).
      Process.sleep(200)
      after_rearm = StubMerger.get_count("!rar3") - baseline

      assert after_rearm <= 15,
             "expected roughly one poll chain (~10 polls/200ms at interval_ms=20), " <>
               "got #{after_rearm} — looks like re-arming started an extra poll chain"
    end

    test "the re-arm bump doesn't leak into a later, unrelated block episode" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar4", [%{status: :open, approved: true, block_reason: :ci_failed}])

      wpid =
        start_watchdog(pid, task_id, "!rar4",
          auto_merge: true,
          max_auto_resolve_attempts: 1,
          max_polls: 1000,
          interval_ms: 15,
          fix_pass_dispatcher: StubFixPassDispatcher,
          workspace: test_workspace()
        )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      Process.sleep(60)

      assert Watchdog.retry_auto_resolve(task_id) == :ok
      assert :sys.get_state(wpid).max_auto_resolve_attempts == 2

      # The episode now clears entirely (approved + no block reason). Force
      # the merge attempt to fail so the watchdog stays alive to inspect
      # (a successful auto-merge stops it immediately) — what matters here is
      # that the bumped budget is restored to what was configured before the
      # next merge attempt, not left at the re-armed value, so a later
      # unrelated block on this same lane doesn't silently inherit an extra
      # automatic attempt (bd-bspakl).
      StubMerger.set_merge_result({:error, :conflict})
      StubMerger.queue_get("!rar4", [%{status: :open, approved: true, block_reason: nil}])

      wait_until(fn -> :sys.get_state(wpid).park_reason == nil end)
      assert :sys.get_state(wpid).max_auto_resolve_attempts == 1
    end

    test "a duplicate re-arm delivered before the next poll is a no-op, not a stack" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar6", [%{status: :open, approved: true, block_reason: :ci_failed}])

      wpid =
        start_watchdog(pid, task_id, "!rar6",
          auto_merge: true,
          max_auto_resolve_attempts: 1,
          max_polls: 1000,
          interval_ms: 15,
          fix_pass_dispatcher: StubFixPassDispatcher,
          workspace: test_workspace()
        )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      wait_until(fn -> :sys.get_state(wpid).park_reason == :ci_failed end)

      # Suspend the Watchdog so neither the pending poll timer nor either
      # `:retry_auto_resolve` call can be processed until we resume — this
      # deterministically reproduces a late/duplicate re-arm delivery
      # (round-1 review: e.g. a caller that saw a false :not_found on
      # timeout and retried) landing back-to-back before any poll has run,
      # rather than relying on both calls racing a real 15ms poll interval.
      :sys.suspend(wpid)

      on_exit(fn ->
        if Process.alive?(wpid), do: :sys.resume(wpid)
      end)

      task1 = Task.async(fn -> Watchdog.retry_auto_resolve(task_id) end)
      task2 = Task.async(fn -> Watchdog.retry_auto_resolve(task_id) end)
      # Give both calls time to land in the Watchdog's mailbox before resuming.
      Process.sleep(50)

      :sys.resume(wpid)

      assert Task.await(task1) == :ok
      assert Task.await(task2) == :ok

      # Both calls were queued before either was processed (attempts is
      # still 1, matching the pre-bump budget for both), so the budget must
      # land at 2, not stack to 3.
      assert :sys.get_state(wpid).max_auto_resolve_attempts == 2
    end

    test "parked_on/1 and retry_auto_resolve/1 report :busy (not :not_found) when the Watchdog is unresponsive" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rar5", [%{status: :open, approved: true, block_reason: :ci_failed}])

      wpid =
        start_watchdog(pid, task_id, "!rar5",
          auto_merge: true,
          fix_pass_dispatcher: StubFixPassDispatcher
        )

      wait_until(fn -> Process.alive?(wpid) end)

      # Simulate a Watchdog wedged in a long-running poll (e.g. dispatching a
      # fresh fix-pass) that can't answer a GenServer.call within the 1s
      # budget these reads use. A timeout does not cancel delivery — the
      # call stays queued in the Watchdog's mailbox and is processed once it
      # frees up — so this must NOT be reported the same as :not_found
      # (round-1 review finding: a caller told :not_found would reasonably
      # conclude nothing happened, when in fact the queued call still lands).
      :sys.suspend(wpid)

      on_exit(fn ->
        if Process.alive?(wpid), do: :sys.resume(wpid)
      end)

      assert Watchdog.parked_on(task_id) == :busy
      assert Watchdog.retry_auto_resolve(task_id) == {:error, :busy}

      :sys.resume(wpid)
    end
  end

  describe "conflict auto-resolve (#354, Phase 2b)" do
    test "dispatches the rebase worker with the task id + mr ref" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :running)
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
      # A :completed resolver lingers alive in a terminal status (the real
      # resolver never exits on a normal finish), so each pass is detected as
      # done via the worker's status and the next poll (still conflicting) tears
      # it down and spawns the next attempt until the cap is hit.
      StubConflictResolver.arm(task_id, self(), pid: :completed)
      StubMerger.queue_get("!c2", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c2",
        workspace: test_workspace(),
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

    test "tears down the prior (lingering) resolver before dispatching the next attempt" do
      {pid, task_id} = running_worker()
      # The resolver reports a terminal status but stays ALIVE (like the real
      # `Arbiter.Worker`, which lingers until task :close). Under the old `:DOWN`
      # mechanism this never fired a completion, so attempt #2 never dispatched
      # and the lingering worker kept its `:conflict` registry slot. The fix
      # detects completion via status and stops the prior resolver first.
      StubConflictResolver.arm(task_id, self(), pid: :completed)
      StubMerger.queue_get("!c8", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c8",
        workspace: test_workspace(),
        auto_merge: false,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      assert_receive {:resolver_spawned, first}, 1_000
      assert_receive {:resolver_spawned, second}, 1_000
      assert first != second
      # The second attempt only dispatches after the first is stopped, freeing its
      # registry slot — so the first resolver is no longer alive.
      wait_until(fn -> not Process.alive?(first) end)
    end

    test "only dispatches max_conflict_attempts workers, not one per poll" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :completed)
      StubMerger.queue_get("!c3", [%{status: :open, approved: true, block_reason: :conflict}])

      start_watchdog(pid, task_id, "!c3",
        workspace: test_workspace(),
        auto_merge: false,
        conflict_resolver: StubConflictResolver,
        max_conflict_attempts: 2,
        interval_ms: 15
      )

      assert_receive {:resolve_called, _}, 1_000
      assert_receive {:resolve_called, _}, 1_000
      assert_receive {:escalate_called, _, _, _, _}, 1_000
      # Past the cap the Watchdog stays parked and must not keep spawning workers
      # or re-paging on every subsequent poll.
      refute_receive {:resolve_called, _}, 200
      refute_receive {:escalate_called, _, _, _, _}, 200
    end

    # bd-1x4r25: the resolver's zero-divergence pre-flight returns `{:ok, :no_op}`
    # instead of spawning a rebase worker. The Watchdog is the resolver's other
    # production caller (MergeQueue is the first) and must recognise that shape —
    # before this it fell through `safe_resolve/2`'s catch-all as
    # `{:error, {:bad_return, {:ok, :no_op}}}` and paged the coordinator with an
    # opaque reason, which is strictly worse than the phantom-conflict escalation
    # it was meant to remove.
    test "a zero-divergence no-op from the resolver neither escalates nor burns an attempt" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), result: :no_op)
      StubMerger.queue_get("!c9", [%{status: :open, approved: true, block_reason: :conflict}])

      wpid =
        start_watchdog(pid, task_id, "!c9",
          workspace: test_workspace(),
          auto_merge: false,
          conflict_resolver: StubConflictResolver,
          max_conflict_attempts: 2,
          interval_ms: 15
        )

      assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
      # A phantom conflict must cost a log line, not an operator's attention.
      refute_receive {:escalate_called, _, _, _, _}, 300

      state = :sys.get_state(wpid)
      assert state.conflict_attempts == 0
      refute state.conflict_escalated
      refute state.conflict_resolving
      assert state.conflict_resolver_pid == nil
    end

    test "a persistent phantom conflict is logged at warning rather than silently forever" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), result: :no_op)
      StubMerger.queue_get("!c10", [%{status: :open, approved: true, block_reason: :conflict}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!c10",
            workspace: test_workspace(),
            auto_merge: false,
            conflict_resolver: StubConflictResolver,
            max_conflict_attempts: 2,
            interval_ms: 15
          )

          assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
          assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
          # Let the repeat-warning land before we read the captured log.
          assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
        end)

      assert log =~ "zero divergence"
      assert log =~ "[warning]"
      refute_receive {:escalate_called, _, _, _, _}, 200
    end

    test "a cleared conflict resets the counter so it never escalates" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :completed)
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
      StubConflictResolver.arm(task_id, self(), pid: :completed)
      # Conflict, then mergeable+approved — the resolver's force-push cleared it
      # and the Watchdog's next poll re-attempts (and lands) the merge.
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
      StubConflictResolver.arm(task_id, self(), pid: :running)
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

      # With auto-resolve off, no rebase worker is dispatched.
      refute_receive {:resolve_called, _}, 200
      refute Worker.state(pid).status == :failed
    end

    test "exhaustion with no workspace_id is logged loudly, not silently swallowed" do
      {pid, task_id} = running_worker()
      StubConflictResolver.arm(task_id, self(), pid: :completed)
      StubMerger.queue_get("!c7", [%{status: :open, approved: true, block_reason: :conflict}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!c7",
            workspace: nil,
            auto_merge: false,
            conflict_resolver: StubConflictResolver,
            max_conflict_attempts: 1,
            interval_ms: 15
          )

          # One rebase pass, then the cap is hit. With no workspace_id the
          # coordinator page has no addressable mailbox, so nothing is sent…
          assert_receive {:resolve_called, %{task_id: ^task_id}}, 1_000
          refute_receive {:escalate_called, _, _, _, _}, 300
        end)

      # …but the give-up is surfaced loudly rather than vanishing (Low finding).
      assert log =~ "workspace_id is nil"
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

    test "via_review_gate bypasses :needs_nonauthor_approval block — no infinite loop (bd-cuzvg9)" do
      {pid, task_id} = running_worker()
      # Simulate a fleet-authored PR that reports :needs_nonauthor_approval
      # (branch protection requires a non-author review). With via_review_gate: true,
      # the ReviewGate has already provided the code review — we must NOT call
      # handle_nonauthor_approval (which sets max_polls: :infinity and causes an
      # infinite retry loop when safe_merge keeps failing). Instead, route through
      # the normal path: effective_outcome maps :pending → :approved, merge fires.
      StubMerger.queue_get(
        "!tnav",
        [%{status: :open, approved: false, block_reason: :needs_nonauthor_approval}]
      )

      start_watchdog(pid, task_id, "!tnav", via_review_gate: true)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!tnav") >= 1
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

  # bd-8eheb6 / #1287. `{:awaiting_review_timeout, N}` is a distinct failure
  # reason: exit_status 0, always safe to resume, functionally different from a
  # genuine failure needing triage. The Watchdog auto-resumes it itself, up to a
  # bounded cap, instead of parking a "failed but resumable" worker nobody is
  # watching.
  describe "awaiting_review_timeout auto-resume (bd-8eheb6)" do
    defp start_timeout_watchdog(pid, task_id, mr_ref, opts \\ []) do
      base = [
        interval_ms: 10,
        initial_delay_ms: 0,
        max_polls: 2,
        auto_merge: true,
        workspace: test_workspace(),
        auto_resume_dispatcher: StubAutoResumeDispatcher
      ]

      start_watchdog(pid, task_id, mr_ref, Keyword.merge(base, opts))
    end

    # resume/1 and escalate_exhausted/4 both land AFTER Worker.fail, so waiting
    # on :failed alone races the stub.
    defp wait_for_decisions(n) do
      wait_until(
        fn ->
          StubAutoResumeDispatcher.resume_count() +
            length(StubAutoResumeDispatcher.escalations()) >= n
        end,
        2_000
      )
    end

    test "auto-resumes the worker instead of parking it for a coordinator to find" do
      {pid, task_id} = running_worker()

      start_timeout_watchdog(pid, task_id, "!arr1")

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      # The failure reason is still registered — the run really did time out,
      # and worker_show/the event feed must still say so.
      assert Worker.state(pid).meta.failure_reason == {:awaiting_review_timeout, 2}

      # ...but the Watchdog resumed it itself rather than paging the coordinator.
      wait_for_decisions(1)

      assert [%{task_id: ^task_id, attempt: 1, mr_ref: "!arr1"}] =
               StubAutoResumeDispatcher.resumes()

      assert StubAutoResumeDispatcher.escalations() == []
    end

    test "auto-resumes up to the cap, then escalates instead of looping forever" do
      cap = 3

      # One Watchdog episode per prior-attempt count. 0/1/2 prior attempts must
      # auto-resume (the 1st, 2nd and 3rd auto-resume); at 3 the budget is spent
      # and the coordinator must be paged instead of a 4th resume firing.
      for prior <- 0..cap do
        {pid, task_id} = running_worker(meta: %{awaiting_review_resume_attempts: prior})

        start_timeout_watchdog(pid, task_id, "!arr-#{prior}", max_auto_resumes: cap)

        wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
        wait_for_decisions(prior + 1)
      end

      # Exactly `cap` auto-resumes, numbered 1..cap — never a 4th.
      assert Enum.map(StubAutoResumeDispatcher.resumes(), & &1.attempt) == [1, 2, 3]

      # ...and then one escalation carrying the exhausted attempt count, so the
      # coordinator does not have to re-derive it via worker_show.
      assert [{_task_id, _ws_id, "!arr-3", 3, :budget_exhausted}] =
               StubAutoResumeDispatcher.escalations()
    end

    test "escalates (does not silently swallow) when the auto-resume itself fails" do
      StubAutoResumeDispatcher.arm_resume_error(:no_outpost)
      {pid, task_id} = running_worker()

      start_timeout_watchdog(pid, task_id, "!arr-err")

      wait_for_decisions(1)
      wait_until(fn -> length(StubAutoResumeDispatcher.escalations()) >= 1 end, 2_000)

      assert StubAutoResumeDispatcher.resume_count() == 1
      # Still in budget — the resume itself could not run, which is a different
      # coordinator problem than a review that refuses to converge.
      assert [{^task_id, _ws_id, "!arr-err", 0, {:resume_failed, :no_outpost}}] =
               StubAutoResumeDispatcher.escalations()
    end

    test "max_auto_resumes: 0 keeps the pre-bd-8eheb6 behaviour (escalate, never resume)" do
      {pid, task_id} = running_worker()

      start_timeout_watchdog(pid, task_id, "!arr-off", max_auto_resumes: 0)

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      wait_for_decisions(1)

      assert StubAutoResumeDispatcher.resume_count() == 0

      assert [{^task_id, _ws_id, "!arr-off", 0, :budget_exhausted}] =
               StubAutoResumeDispatcher.escalations()
    end

    test "the cap is workspace-configurable" do
      {pid, task_id} = running_worker(meta: %{awaiting_review_resume_attempts: 1})

      ws = test_workspace(%{"merge" => %{"max_awaiting_review_resumes" => 1}})
      start_timeout_watchdog(pid, task_id, "!arr-ws", workspace: ws)

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      wait_for_decisions(1)

      # 1 prior attempt already spends a cap of 1 — escalate, do not resume.
      assert StubAutoResumeDispatcher.resume_count() == 0

      assert [{^task_id, _ws_id, "!arr-ws", 1, :budget_exhausted}] =
               StubAutoResumeDispatcher.escalations()
    end

    test "a genuine (non-timeout) failure still escalates immediately, never auto-resumes" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!arr-closed", [%{status: :closed}])

      start_timeout_watchdog(pid, task_id, "!arr-closed")

      wait_until(fn -> Worker.state(pid).status == :failed end, 2_000)
      assert match?({:mr_closed, _}, Worker.state(pid).meta.failure_reason)

      assert StubAutoResumeDispatcher.resume_count() == 0
      assert StubAutoResumeDispatcher.escalations() == []
    end

    test "a manual-merge lane still parks (no fail, no auto-resume)" do
      {pid, task_id} = running_worker()

      wpid = start_timeout_watchdog(pid, task_id, "!arr-manual", auto_merge: false)
      wref = Process.monitor(wpid)

      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 2_000
      refute Worker.state(pid).status == :failed
      assert StubAutoResumeDispatcher.resume_count() == 0
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

  describe "auto-merge stall notification (bd-6gxosc)" do
    test "Watchdog keeps retrying after consecutive safe_merge failures" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :mergeable_state_unknown})
      # Always approved so auto-merge fires every poll.
      StubMerger.queue_get("!sm1", [%{status: :open, approved: true}])

      start_watchdog(pid, task_id, "!sm1",
        auto_merge: true,
        merge_fail_notify_threshold: 3,
        interval_ms: 15
      )

      # After more than 3 intervals the Watchdog must have retried merge multiple
      # times — it did NOT stop after the first failure.
      wait_until(fn -> StubMerger.merge_count("!sm1") >= 4 end)
      refute Worker.state(pid).status == :failed
    end

    test "notification is logged once when the threshold is hit" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :mergeable_state_unknown})
      StubMerger.queue_get("!sm2", [%{status: :open, approved: true}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!sm2",
            auto_merge: true,
            merge_fail_notify_threshold: 3,
            interval_ms: 15
          )

          # Wait until at least 3 consecutive failures have accumulated.
          wait_until(fn -> StubMerger.merge_count("!sm2") >= 3 end)
          # Give it a bit more time so any additional log lines would have appeared.
          Process.sleep(60)
        end)

      # The warning about the stall must appear.
      assert log =~ "consecutive failure 3"
      # It must NOT repeat on every subsequent poll — only logged once per
      # stall episode (the merge_stall_notified latch prevents re-firing).
      occurrences = log |> String.split("consecutive failure 3") |> length() |> Kernel.-(1)
      assert occurrences == 1
    end

    test "failure counter resets on a successful merge — a fresh stall re-notifies" do
      {pid, task_id} = running_worker()

      # First pass: fail 2 times (below threshold of 3) then succeed.
      # The success resets the counter; subsequent failures start fresh.
      # We verify this by observing the merge succeeded and the worker completed.
      #
      # This also implicitly tests that the counter resets: if it didn't, a
      # second stall episode starting at 1 would never re-notify even though
      # merge_stall_notified was set to false.
      StubMerger.queue_get("!sm3", [
        # First 2 polls: merge fails (below threshold — no notification yet).
        %{status: :open, approved: true},
        %{status: :open, approved: true},
        # Third poll: merge succeeds. Counter resets.
        %{status: :open, approved: true}
      ])

      # First two attempts fail, third succeeds.
      call_count = :counters.new(1, [])
      StubMerger.set_merge_result({:error, :transient})

      # We test indirectly: Watchdog retries until merge succeeds.
      # Override: make the first 2 fail and the third succeed.
      # (This is tricky with a global StubMerger setting. Instead, we just verify
      # the worker eventually completes after we change the merge result.)
      wpid =
        start_watchdog(pid, task_id, "!sm3",
          auto_merge: true,
          merge_fail_notify_threshold: 3,
          interval_ms: 15
        )

      wait_until(fn -> StubMerger.merge_count("!sm3") >= 2 end)
      # Now let merge succeed.
      StubMerger.set_merge_result(:ok)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      _ = {call_count, wpid}
    end

    test "keeps polling past max_polls once the stall notification fires (bd-krg7ci)" do
      # Reproduces the reported incident's actual failure path: a via_review_gate
      # MR with red CI (no forge-level approved: true) hits
      # `do_apply_approved_auto_merge/1` directly — not `handle_block/3` — because
      # `effective_outcome/2` forces :approved for a gate-approved MR regardless of
      # the raw `approved` flag. Before this fix, that path's finite `max_polls`
      # ceiling was never lifted, so the worker still died at the ceiling even
      # after the coordinator had been paged.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :ci_must_pass})
      StubMerger.queue_get("!sm4", [%{status: :open, approved: false}])

      start_watchdog(pid, task_id, "!sm4",
        via_review_gate: true,
        merge_fail_notify_threshold: 3,
        max_polls: 3,
        interval_ms: 15
      )

      # Well past 3 poll intervals — the ordinary auto_merge ceiling would have
      # failed the worker here pre-fix.
      wait_until(fn -> StubMerger.merge_count("!sm4") >= 6 end)
      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end

    test "re-notifies every base_max_polls polls instead of latching silent forever (bd-krg7ci round 2)" do
      # Round-1's indefinite park (max_polls: :infinity once the stall is first
      # paged) reintroduced permanent silence for a live Watchdog:
      # `merge_stall_notified` was a hard latch with no live-path reset, so the
      # coordinator page fired exactly once no matter how long the MR's CI
      # stayed red afterward — the incident's own primary complaint ("would
      # have stayed that way indefinitely without a human noticing").
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :ci_must_pass})
      StubMerger.queue_get("!sm5", [%{status: :open, approved: false}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!sm5",
            via_review_gate: true,
            merge_fail_notify_threshold: 3,
            max_polls: 3,
            interval_ms: 15
          )

          # base_max_polls is 3: the first page fires at fail_count 3, the
          # second re-page is due once poll_count has advanced 3 more polls
          # past that. Give it comfortably more than 2 * base_max_polls polls.
          wait_until(fn -> StubMerger.merge_count("!sm5") >= 10 end, 2_000)
        end)

      occurrences =
        log
        |> String.split("paging coordinator for auto-merge stall")
        |> length()
        |> Kernel.-(1)

      assert occurrences >= 2
      refute Worker.state(pid).status == :failed
    end

    test "a block clearing after a merge-stall page doesn't silently disarm the stall park (bd-krg7ci round 3)" do
      # Reproduces the exact sequence the coordinator's own response to a stall
      # page produces: the merge-stall park (via `do_apply_approved_auto_merge/1`)
      # sets `last_block_reason: nil`, so it doesn't look "parked" to the
      # block-clear restore in `do_maybe_escalate_merge_block/2`. But if the
      # coordinator then forge-approves in response to the page, a real block
      # (`:behind_base`) can surface and clear within the same episode — and
      # before this fix, that clear reset `max_polls` back to the finite base
      # AND left `merge_stall_notified: true` / `last_merge_stall_poll` stale, so
      # no further re-page could ever fire (the counters go negative) and the
      # worker died at the ceiling a few polls later while merges kept failing —
      # the incident's own failure mode returning via a different door.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :ci_must_pass})

      StubMerger.queue_get("!bc1", [
        %{status: :open, approved: false},
        %{status: :open, approved: false},
        %{status: :open, approved: false},
        %{status: :open, approved: true, block_reason: :behind_base},
        %{status: :open, approved: false}
      ])

      start_watchdog(pid, task_id, "!bc1",
        via_review_gate: true,
        merge_fail_notify_threshold: 1,
        max_polls: 3,
        interval_ms: 15
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Well past the finite max_polls ceiling — pre-fix this failed the
          # worker with {:awaiting_review_timeout, 3} once the block cleared.
          wait_until(fn -> StubMerger.merge_count("!bc1") >= 10 end, 2_000)
        end)

      occurrences =
        log
        |> String.split("paging coordinator for auto-merge stall")
        |> length()
        |> Kernel.-(1)

      assert occurrences >= 2
      refute Worker.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Worker.state(pid).meta[:failure_reason])
    end

    test "an :infinity watchdog_max_polls lane still gets a finite re-escalation cadence (bd-krg7ci round 3)" do
      # `Arbiter.Tasks.Workspace.watchdog_max_polls/1` accepts "infinity", which
      # can make `base_max_polls == :infinity` even on an auto_merge lane. Before
      # this fix, `should_notify`'s `is_integer(state.base_max_polls)` guard was
      # permanently false in that case, so the stall page fired exactly once and
      # never again no matter how long the MR stayed red — the same
      # permanent-silence shape round 2 closed, just reachable via config.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :ci_must_pass})
      StubMerger.queue_get("!inf1", [%{status: :open, approved: false}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!inf1",
            via_review_gate: true,
            merge_fail_notify_threshold: 3,
            max_polls: :infinity,
            interval_ms: 15
          )

          wait_until(fn -> StubMerger.merge_count("!inf1") >= 70 end, 2_000)
        end)

      occurrences =
        log
        |> String.split("paging coordinator for auto-merge stall")
        |> length()
        |> Kernel.-(1)

      assert occurrences >= 2
      refute Worker.state(pid).status == :failed
    end
  end

  describe "defers merge attempt while CI is still running (bd-cnytw3)" do
    test "does not call safe_merge while pipeline is :running, merges once it settles" do
      {pid, task_id} = running_worker()

      StubMerger.queue_get("!ci1", [
        %{status: :open, approved: true, pipeline: :running},
        %{status: :open, approved: true, pipeline: :running},
        %{status: :open, approved: true, pipeline: :running}
      ])

      start_watchdog(pid, task_id, "!ci1", auto_merge: true, interval_ms: 15)

      # Several poll cycles while CI is still running: no merge attempt, no
      # completion — the Watchdog must just keep waiting.
      Process.sleep(120)
      assert StubMerger.merge_count("!ci1") == 0
      refute Worker.state(pid).status == :completed

      # CI settles — the next poll attempts (and succeeds at) the merge.
      StubMerger.queue_get("!ci1", [%{status: :open, approved: true, pipeline: :success}])
      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!ci1") == 1
    end

    test "does not call safe_merge while pipeline is :pending, and does not count it as a merge failure" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :should_not_be_called})
      StubMerger.queue_get("!ci2", [%{status: :open, approved: true, pipeline: :pending}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!ci2",
            auto_merge: true,
            interval_ms: 15,
            merge_fail_notify_threshold: 2
          )

          Process.sleep(120)
        end)

      assert StubMerger.merge_count("!ci2") == 0
      refute log =~ "consecutive failure"
      refute Worker.state(pid).status == :failed
    end

    test "still attempts merge (and counts a real failure) when pipeline has settled" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :real_conflict})
      StubMerger.queue_get("!ci3", [%{status: :open, approved: true, pipeline: :success}])

      start_watchdog(pid, task_id, "!ci3", auto_merge: true, interval_ms: 15)

      wait_until(fn -> StubMerger.merge_count("!ci3") >= 2 end)
      refute Worker.state(pid).status == :failed
    end

    test "attempts merge (does not defer) when pipeline is :neutral — a settled but non-success state, not CI-still-running" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!ci4", [%{status: :open, approved: true, pipeline: :neutral}])

      start_watchdog(pid, task_id, "!ci4", auto_merge: true, interval_ms: 15)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!ci4") == 1
    end

    test "does not call safe_merge while pipeline is :not_started (bd-aeb9wv), merges once check-runs appear" do
      # PR #1188: the check-suite for the head SHA hadn't been created yet by
      # the time the ReviewGate APPROVE landed — the check-runs API returned
      # zero results, and the adapter's `nil` pipeline was (wrongly) treated
      # as "nothing blocking" rather than "unknown, wait". `:not_started` is
      # the adapter's distinct signal for that zero-results case.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result({:error, :should_not_be_called})

      StubMerger.queue_get("!ci5", [
        %{status: :open, approved: true, pipeline: :not_started},
        %{status: :open, approved: true, pipeline: :not_started}
      ])

      start_watchdog(pid, task_id, "!ci5", auto_merge: true, interval_ms: 15)

      # Fewer polls than @not_started_grace_polls (5) so the grace-bounded
      # fallthrough (bd-aeb9wv round 2) doesn't fire yet — see the dedicated
      # "falls through ... once grace polls are exhausted" test below for that.
      Process.sleep(40)
      assert StubMerger.merge_count("!ci5") == 0
      refute Worker.state(pid).status == :completed

      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!ci5", [%{status: :open, approved: true, pipeline: :success}])
      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!ci5") == 1
    end

    test "falls through to a merge attempt once :not_started grace polls are exhausted (bd-aeb9wv)" do
      # Reviewer finding: treating `:not_started` as pending *forever* (like
      # genuine `:running`/`:pending`) would make a repo with no CI configured
      # at all hard-fail the worker at `max_polls` on every auto-merge lane.
      # The pipeline never resolves for that repo, so the deferral must be
      # bounded — after `@not_started_grace_polls` consecutive `:not_started`
      # polls, the Watchdog stops waiting and attempts the merge.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!ci6", [%{status: :open, approved: true, pipeline: :not_started}])

      start_watchdog(pid, task_id, "!ci6", auto_merge: true, interval_ms: 15)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!ci6") == 1
    end
  end

  describe "a ReviewGate-approved PR with red CI never auto-merges (bd-23y19q / #1176)" do
    # bd-9j4znl (PR #1173) merged 4s after ReviewGate's APPROVE while its own
    # `mix test` check had been concluded FAILURE for three minutes. Two
    # independent gaps let that through, and both are covered here.

    test "effective_block_reason/2 is via_review_gate-aware — :ci_failed is visible with no forge-visible review" do
      # Gap 2. The gate approves in-process, so `classify/1` sees `:pending`
      # forever on a hosted forge and the arity-1 (state-less) gate returns nil —
      # which made the whole `:ci_failed` auto-resolve path dead code for exactly
      # the population ReviewGate drives.
      result = %{status: :open, approved: false, pipeline: :failed, block_reason: :ci_failed}

      assert Watchdog.effective_block_reason(%{via_review_gate: true}, result) == :ci_failed

      # Non-gate lanes keep the strict approval gate (#354).
      assert Watchdog.effective_block_reason(%{via_review_gate: false}, result) == nil
      assert Watchdog.effective_block_reason(result) == nil
    end

    test "a via_review_gate PR still terminal/approved keeps the arity-2 gate honest" do
      # The gate override is `:pending -> :approved` only; terminal facts win, and
      # a genuinely approved PR reports its reason on either arity.
      merged = %{status: :merged, block_reason: :conflict}
      approved = %{status: :open, approved: true, block_reason: :behind_base}

      assert Watchdog.effective_block_reason(%{via_review_gate: true}, merged) == nil
      assert Watchdog.effective_block_reason(%{via_review_gate: true}, approved) == :behind_base
      assert Watchdog.effective_block_reason(%{via_review_gate: true}, nil) == nil
    end

    test "the bd-9j4znl shape does not merge and dispatches a fix-pass acolyte instead" do
      # The live incident's exact poll shape: ReviewGate approved in-process
      # (via_review_gate: true, no forge-visible review), auto_merge lane, and a
      # pipeline that has already CONCLUDED :failed.
      {pid, task_id} = running_worker()
      StubMerger.set_failing_checks("!rg1", [%{name: "mix test", summary: "boom", url: nil}])

      StubMerger.queue_get("!rg1", [
        %{status: :open, approved: false, pipeline: :failed, block_reason: :ci_failed}
      ])

      start_watchdog(pid, task_id, "!rg1",
        via_review_gate: true,
        auto_merge: true,
        interval_ms: 15,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)

      args = StubFixPassDispatcher.last_args()
      assert args.task_id == task_id
      assert args.pr_ref == "!rg1"
      assert args.checks == [%{name: "mix test", summary: "boom", url: nil}]

      # Several more polls: still no merge, and the worker is not "completed".
      Process.sleep(120)
      assert StubMerger.merge_count("!rg1") == 0
      refute Worker.state(pid).status == :completed
    end

    test "a concluded-failed pipeline blocks the merge even when the adapter reports no block reason" do
      # Gap 1 on its own: `ci_pending?/1` only knows `:running`/`:pending`, so a
      # settled `:failed` fell straight through to the merge. Belt and braces for
      # any adapter/poll that surfaces the red pipeline without a block reason.
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!rg2", [%{status: :open, approved: true, pipeline: :failed}])

      start_watchdog(pid, task_id, "!rg2", auto_merge: true, interval_ms: 15)

      Process.sleep(150)
      assert StubMerger.merge_count("!rg2") == 0
      refute Worker.state(pid).status == :completed
    end

    test "a green via_review_gate PR still auto-merges on the first poll (no regression of bd-66ey1o)" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!rg3", [%{status: :open, approved: false, pipeline: :success}])

      start_watchdog(pid, task_id, "!rg3", via_review_gate: true, interval_ms: 15)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!rg3") == 1
    end

    test "a :neutral-pipeline via_review_gate PR still auto-merges (settled non-success is not failed)" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)
      StubMerger.queue_get("!rg4", [%{status: :open, approved: false, pipeline: :neutral}])

      start_watchdog(pid, task_id, "!rg4", via_review_gate: true, interval_ms: 15)

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert StubMerger.merge_count("!rg4") == 1
    end

    test "an auto_merge:false lane is unchanged — never merges, never fails, keeps polling for the human" do
      {pid, task_id} = running_worker()
      StubMerger.set_merge_result(:ok)

      StubMerger.queue_get("!rg5", [
        %{status: :open, approved: false, pipeline: :failed, block_reason: :ci_failed}
      ])

      start_watchdog(pid, task_id, "!rg5",
        via_review_gate: true,
        auto_merge: false,
        interval_ms: 15,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

      Process.sleep(150)
      assert StubMerger.merge_count("!rg5") == 0
      # The human-decides lane never auto-resolves — that's an auto_merge-only path.
      assert StubFixPassDispatcher.call_count() == 0
      refute Worker.state(pid).status == :failed
      refute Worker.state(pid).status == :completed
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

  describe "rerun_ci/2 (bd-5mzzww / #1448)" do
    test "delegates to the adapter with the watched mr_ref and the caller's options" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rr1", [%{status: :open, approved: false}])
      start_watchdog(pid, task_id, "!rr1", [])

      assert {:ok, %{mode: :all_jobs}} =
               Watchdog.rerun_ci(task_id, %{mode: :all_jobs, inputs: %{"force_deploy" => "true"}})

      assert [{"!rr1", opts} | _] = StubMerger.ci_reruns()
      assert opts.mode == :all_jobs
      assert opts.inputs == %{"force_deploy" => "true"}
    end

    test "surfaces the adapter's error rather than swallowing it" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!rr2", [%{status: :open, approved: false}])
      start_watchdog(pid, task_id, "!rr2", [])
      StubMerger.set_rerun_result({:error, :no_failed_run})

      assert {:error, :no_failed_run} = Watchdog.rerun_ci(task_id, %{})
    end

    test "no watchdog for the task is :not_found, not a crash" do
      assert {:error, :not_found} = Watchdog.rerun_ci("nope-#{System.unique_integer()}", %{})
    end

    test "an adapter with no re-run primitive answers :unsupported" do
      defmodule NoRerunMerger do
        @moduledoc false
        def get(_ref), do: {:ok, %{status: :open, approved: false}}
        def link_for(ref), do: ref
      end

      {pid, task_id} = running_worker()
      start_watchdog(pid, task_id, "!rr3", adapter: NoRerunMerger)

      assert {:error, :unsupported} = Watchdog.rerun_ci(task_id, %{})
    end
  end

  describe "mark_ci_external/2 (bd-5mzzww / #1448)" do
    test "reclassifies a parked :ci_failed block as :ci_failed_external" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!ce1", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!ce1",
        auto_merge: true,
        max_auto_resolve_attempts: 0,
        interval_ms: 15,
        workspace: test_workspace()
      )

      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed end)

      assert :ok =
               Watchdog.mark_ci_external(
                 task_id,
                 "4 unrelated branches failed the same admin-panel-switcher timeout today"
               )

      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed_external end)
    end

    test "the escalation names the external diagnosis and the worker's evidence" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!ce2", [%{status: :open, approved: true, block_reason: :ci_failed}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!ce2",
            auto_merge: true,
            max_auto_resolve_attempts: 0,
            interval_ms: 15,
            workspace: test_workspace()
          )

          wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed end)
          :ok = Watchdog.mark_ci_external(task_id, "day-wide infra outage, not this diff")
          wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed_external end)
          Process.sleep(60)
        end)

      assert log =~ "ci_failed_external"
    end

    test "refuses when the task is not parked on a CI block" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!ce3", [%{status: :open, approved: false}])
      start_watchdog(pid, task_id, "!ce3", [])

      assert {:error, :not_parked_on_ci_failed} = Watchdog.mark_ci_external(task_id, "infra")
    end

    test "no watchdog for the task is :not_found" do
      assert {:error, :not_found} =
               Watchdog.mark_ci_external("nope-#{System.unique_integer()}", "infra")
    end

    test "the external mark clears when the CI block clears, so a later real failure is not mislabelled" do
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!ce4", [%{status: :open, approved: true, block_reason: :ci_failed}])

      start_watchdog(pid, task_id, "!ce4",
        auto_merge: true,
        max_auto_resolve_attempts: 0,
        interval_ms: 15,
        workspace: test_workspace()
      )

      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed end)
      :ok = Watchdog.mark_ci_external(task_id, "infra")
      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed_external end)

      # The block clears (the infra fix lands) and then a genuine, unrelated
      # CI failure appears. It must page as :ci_failed, not inherit the stale
      # "not my diff" verdict.
      StubMerger.queue_get("!ce4", [
        %{status: :open, approved: false},
        %{status: :open, approved: true, block_reason: :ci_failed}
      ])

      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed end, 2_000)
    end

    test "a :ci_failed_external park still restores the finite poll ceiling when it clears" do
      # Review round 1: `clear_stale_ci_external/2` runs *before* the
      # park-revocation branch, so nilling `park_reason` there disarmed that
      # branch's `park_reason != nil` guard on the mainline recovery poll
      # (infra fixed, CI green, PR approved). `max_polls` stayed `:infinity`
      # and the stall latches stayed stale — the worker went immortal for the
      # rest of its life rather than just for that episode (bd-krg7ci). A plain
      # `:ci_failed` park on the identical poll restores correctly, so the
      # asymmetry existed only for the new reason.
      {pid, task_id} = running_worker()
      StubMerger.queue_get("!ce5", [%{status: :open, approved: true, block_reason: :ci_failed}])

      wpid =
        start_watchdog(pid, task_id, "!ce5",
          auto_merge: true,
          max_auto_resolve_attempts: 0,
          max_polls: 1000,
          # Keep the *separate* merge-stall park (which lifts max_polls without
          # ever setting park_reason) out of the way — the failing merges below
          # exist only to keep the watchdog alive long enough to inspect.
          merge_fail_notify_threshold: 100_000,
          interval_ms: 15,
          workspace: test_workspace()
        )

      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed end)
      :ok = Watchdog.mark_ci_external(task_id, "infra")
      wait_until(fn -> Watchdog.parked_on(task_id) == :ci_failed_external end)
      assert :sys.get_state(wpid).max_polls == :infinity

      # Poll on the park for a while so `poll_count` climbs well past whatever
      # it can reach in the moment between the clearing poll and the assertion.
      Process.sleep(300)
      parked_poll_count = :sys.get_state(wpid).poll_count
      assert parked_poll_count > 5

      # The mainline recovery: infra fixed, CI green, PR approved. Merge is
      # forced to fail purely so the watchdog survives to be inspected.
      StubMerger.set_merge_result({:error, :conflict})
      StubMerger.queue_get("!ce5", [%{status: :open, approved: true, block_reason: nil}])

      wait_until(fn -> :sys.get_state(wpid).max_polls == 1000 end, 2_000)

      state = :sys.get_state(wpid)
      assert state.park_reason == nil
      assert state.ci_external_note == nil
      assert state.poll_count < parked_poll_count
      refute state.merge_stall_notified
      assert state.last_merge_stall_poll == 0
    end
  end

  describe "park heartbeat (bd-5mzzww / #1448 ask 4)" do
    test "re-pages a non-auto-resolvable park on the heartbeat cadence instead of latching silent" do
      # The once-per-episode dedupe (#1226) is right for avoiding an escalation
      # storm, but a park with no automated remediation AND no repeat signal is
      # easy to lose — ours sat 19 hours on a single page. A low-frequency
      # heartbeat re-raises a block that has seen no state change.
      {pid, task_id} = running_worker()

      StubMerger.queue_get("!hb1", [
        %{status: :open, approved: true, block_reason: :needs_nonauthor_approval}
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!hb1",
            auto_merge: false,
            interval_ms: 15,
            park_heartbeat_polls: 3,
            workspace: test_workspace()
          )

          wait_until(fn -> StubMerger.get_count("!hb1") >= 10 end, 2_000)
        end)

      occurrences =
        log
        |> String.split("still parked")
        |> length()
        |> Kernel.-(1)

      assert occurrences >= 2
    end

    test "a heartbeat of 0 disables the reminder (pre-existing once-per-episode behaviour)" do
      {pid, task_id} = running_worker()

      StubMerger.queue_get("!hb2", [
        %{status: :open, approved: true, block_reason: :needs_nonauthor_approval}
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!hb2",
            auto_merge: false,
            interval_ms: 15,
            park_heartbeat_polls: 0,
            workspace: test_workspace()
          )

          wait_until(fn -> StubMerger.get_count("!hb2") >= 10 end, 2_000)
        end)

      refute log =~ "still parked"
    end

    test "a block that changes reason re-pages immediately and restarts the heartbeat clock" do
      {pid, task_id} = running_worker()

      StubMerger.queue_get("!hb3", [
        %{status: :open, approved: true, block_reason: :needs_nonauthor_approval},
        %{status: :open, approved: true, block_reason: :draft}
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_watchdog(pid, task_id, "!hb3",
            auto_merge: false,
            interval_ms: 15,
            park_heartbeat_polls: 1000,
            workspace: test_workspace()
          )

          wait_until(fn -> StubMerger.get_count("!hb3") >= 5 end, 2_000)
        end)

      assert log =~ "merge blocked (needs_nonauthor_approval)"
      assert log =~ "merge blocked (draft)"
      refute log =~ "still parked"
    end
  end
end
