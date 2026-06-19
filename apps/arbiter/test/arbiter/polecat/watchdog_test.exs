defmodule Arbiter.Polecat.WatchdogTest do
  # async: false — shares the singleton Polecat registry/supervisor and the
  # named StubMerger Agent. Unique bead_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecat.Watchdog
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_bead_id, do: "watchdog-test-#{System.unique_integer([:positive])}"

  # A :running polecat the Watchdog can drive to a terminal state.
  defp running_polecat do
    bead_id = new_bead_id()
    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter")
    :ok = Polecat.advance(pid, :implement)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, bead_id}
  end

  defp start_watchdog(polecat_pid, bead_id, mr_ref, opts) do
    base = [
      bead_id: bead_id,
      polecat: polecat_pid,
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
    test "merged MR completes the polecat and stops the watchdog" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!1", [%{status: :merged}])

      wpid = start_watchdog(pid, bead_id, "!1", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert Polecat.state(pid).meta.result == :merged
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "closed MR fails the polecat with :mr_closed and stops the watchdog" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!2", [%{status: :closed}])

      wpid = start_watchdog(pid, bead_id, "!2", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Polecat.state(pid).status == :failed end)
      assert Polecat.state(pid).meta.failure_reason == {:mr_closed, "!2"}
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "approved + auto_merge merges then completes" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!3", [%{status: :open, approved: true}])

      start_watchdog(pid, bead_id, "!3", auto_merge: true)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert StubMerger.merge_count("!3") == 1
    end

    test "approved without auto_merge parks until a later poll sees merged" do
      {pid, bead_id} = running_polecat()
      # First poll: approved but not merged -> stay parked (no merge call).
      # Second poll: merged -> complete.
      StubMerger.queue_get("!4", [%{status: :open, approved: true}, %{status: :merged}])

      start_watchdog(pid, bead_id, "!4", auto_merge: false)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert StubMerger.merge_count("!4") == 0
    end

    test "records the last merger status + checked timestamp on the polecat" do
      {pid, bead_id} = running_polecat()
      # Stay pending so the watchdog keeps polling and we can observe the record.
      StubMerger.queue_get("!5", [%{status: :open, approved: false}])

      start_watchdog(pid, bead_id, "!5", [])

      wait_until(fn ->
        meta = Polecat.state(pid).meta
        status = Map.get(meta, :last_merger_status)

        is_map(status) and
          Map.get(status, :status) == :open and
          Map.get(status, :approved) == false and
          match?(%DateTime{}, Map.get(meta, :last_checked_at))
      end)
    end
  end

  describe "via_review_gate short-circuits forge approval (bd-66ey1o)" do
    test "treats :pending as :approved and force-auto-merges on first poll" do
      {pid, bead_id} = running_polecat()
      # No approval — pure :pending sequence — but via_review_gate must flip it
      # to :approved so the merge fires anyway.
      StubMerger.queue_get("!t1", [%{status: :open, approved: false}])

      start_watchdog(pid, bead_id, "!t1", via_review_gate: true)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert Polecat.state(pid).meta.result == :merged
      assert StubMerger.merge_count("!t1") >= 1
    end

    test "via_review_gate still defers to :merged and :closed terminal status" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!t2", [%{status: :closed}])

      start_watchdog(pid, bead_id, "!t2", via_review_gate: true)

      wait_until(fn -> Polecat.state(pid).status == :failed end)
      assert Polecat.state(pid).meta.failure_reason == {:mr_closed, "!t2"}
      # Importantly: we did NOT call merge/1 on a closed MR even though
      # via_review_gate was on. Approval overriding is for :pending only.
      assert StubMerger.merge_count("!t2") == 0
    end
  end

  describe "watchdog (bd-66ey1o / bd-akr4il)" do
    test "fails the polecat after max_polls on auto_merge: true lanes" do
      {pid, bead_id} = running_polecat()
      # auto_merge ON: if the forge never auto-merges after cap polls something
      # is broken — fail loudly so the bead surfaces in the notification feed.
      start_watchdog(pid, bead_id, "!w1",
        interval_ms: 10,
        initial_delay_ms: 0,
        max_polls: 2,
        auto_merge: true
      )

      wait_until(fn -> Polecat.state(pid).status == :failed end, 2_000)
      assert Polecat.state(pid).meta.failure_reason == {:awaiting_review_timeout, 2}
    end

    test "parks (does not fail) the polecat after max_polls on auto_merge: false lanes" do
      {pid, bead_id} = running_polecat()
      # auto_merge OFF (human-merge): a reviewer may take hours or overnight.
      # Hitting the poll cap must NOT fail the bead — the polecat stays parked
      # at :awaiting_review and the Watchdog stops to free resources (bd-akr4il).
      wpid =
        start_watchdog(pid, bead_id, "!w3",
          interval_ms: 10,
          initial_delay_ms: 0,
          max_polls: 2,
          auto_merge: false
        )

      wref = Process.monitor(wpid)

      # Watchdog stops without failing the polecat.
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 2_000
      refute Polecat.state(pid).status == :failed
      refute match?({:awaiting_review_timeout, _}, Polecat.state(pid).meta[:failure_reason])
    end

    test "does not fire when via_review_gate: true (merge happens before cap)" do
      {pid, bead_id} = running_polecat()

      start_watchdog(pid, bead_id, "!w2",
        via_review_gate: true,
        interval_ms: 10,
        initial_delay_ms: 0,
        max_polls: 2
      )

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      refute match?({:awaiting_review_timeout, _}, Polecat.state(pid).meta[:failure_reason])
    end
  end

  describe "pipeline watching (watch_pipeline: true)" do
    test "does not escalate when watch_pipeline is false (default)" do
      {pid, bead_id} = running_polecat()
      # Pipeline is :failed but watch_pipeline not set — polecat should just
      # keep polling and eventually complete (not escalate or fail early).
      StubMerger.queue_get("!p1", [
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :merged}
      ])

      start_watchdog(pid, bead_id, "!p1", [])

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      # The key assertion: with watch_pipeline off, a :failed pipeline must not
      # fail the polecat — it should still complete when the MR merges.
      assert Polecat.state(pid).status == :completed
    end

    test "stays parked when pipeline is :failed and watch_pipeline is true" do
      {pid, bead_id} = running_polecat()
      # First two polls: pipeline :failed, MR still open — should stay parked.
      # Third poll: MR merged — should complete.
      StubMerger.queue_get("!p2", [
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :open, approved: false, pipeline: :failed},
        %{status: :merged}
      ])

      start_watchdog(pid, bead_id, "!p2", watch_pipeline: true)

      # Wait until merged — the pipeline failure must not have failed the bead.
      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert Polecat.state(pid).status == :completed
      assert Polecat.state(pid).meta[:failure_reason] == nil
    end

    test "pipeline :success does not affect normal MR flow" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!p3", [%{status: :merged, pipeline: :success}])

      start_watchdog(pid, bead_id, "!p3", watch_pipeline: true)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert Polecat.state(pid).status == :completed
    end
  end

  describe "lifecycle" do
    test "stops when the watched polecat dies" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!6", [%{status: :open, approved: false}])

      wpid = start_watchdog(pid, bead_id, "!6", [])
      ref = Process.monitor(wpid)

      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "init returns :ignore when the polecat is already gone" do
      assert Watchdog.start_link(
               bead_id: "gone",
               polecat: "no-such-bead",
               mr_ref: "!7",
               adapter: StubMerger
             ) == :ignore
    end

    # bd-91rnwq: DynamicSupervisor.start_child propagates :ignore from
    # Watchdog.init directly (not wrapped in {:error, ...}). The unhandled :ignore
    # in start_watchdog/3's case clause was the root cause of the CaseClauseError
    # that crashed the polecat after a successful MR creation.
    test "start/1 via DynamicSupervisor returns :ignore when polecat is already gone" do
      assert Watchdog.start(
               bead_id: "gone-ds",
               polecat: "no-such-bead",
               mr_ref: "!ignore-ds",
               adapter: StubMerger,
               workspace: nil
             ) == :ignore
    end
  end

  describe "open_mr resilience (bd-91rnwq)" do
    test "Polecat.open_mr/5 transitions to :awaiting_review on successful MR creation" do
      # Regression guard: open_mr must always reach :awaiting_review when
      # safe_open succeeds, regardless of what start_watchdog does internally.
      # Before the fix, a CaseClauseError in start_watchdog propagated uncaught
      # through handle_call and crashed the polecat, orphaning the MR.
      {pid, _bead_id} = running_polecat()
      StubMerger.next_open_ref("!oom1")
      StubMerger.queue_get("!oom1", [%{status: :open, approved: false}])

      {:ok, mr_ref} =
        Polecat.open_mr(pid, "feature/x", "Fix it", "", %{adapter: StubMerger, workspace: nil})

      assert mr_ref == "!oom1"
      assert Polecat.state(pid).status == :awaiting_review
      assert Polecat.state(pid).mr_ref == "!oom1"
    end
  end
end
