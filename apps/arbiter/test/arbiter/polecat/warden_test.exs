defmodule Arbiter.Polecat.WardenTest do
  # async: false — shares the singleton Polecat registry/supervisor and the
  # named StubMerger Agent. Unique bead_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecat.Warden
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_bead_id, do: "warden-test-#{System.unique_integer([:positive])}"

  # A :running polecat the Warden can drive to a terminal state.
  defp running_polecat do
    bead_id = new_bead_id()
    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter")
    :ok = Polecat.advance(pid, :implement)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, bead_id}
  end

  defp start_warden(polecat_pid, bead_id, mr_ref, opts) do
    base = [
      bead_id: bead_id,
      polecat: polecat_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: nil,
      interval_ms: 20,
      initial_delay_ms: 0
    ]

    {:ok, wpid} = Warden.start(Keyword.merge(base, opts))
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
      assert Warden.classify(%{status: :merged}) == :merged
      assert Warden.classify(%{status: :merged, approved: true}) == :merged
    end

    test "closed is terminal-fail" do
      assert Warden.classify(%{status: :closed}) == :closed
    end

    test "approved (not merged) is :approved" do
      assert Warden.classify(%{status: :open, approved: true}) == :approved
    end

    test "everything else is :pending" do
      assert Warden.classify(%{status: :open, approved: false}) == :pending
      assert Warden.classify(%{}) == :pending
    end
  end

  describe "poll outcomes" do
    test "merged MR completes the polecat and stops the warden" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!1", [%{status: :merged}])

      wpid = start_warden(pid, bead_id, "!1", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert Polecat.state(pid).meta.result == :merged
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "closed MR fails the polecat with :mr_closed and stops the warden" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!2", [%{status: :closed}])

      wpid = start_warden(pid, bead_id, "!2", [])
      ref = Process.monitor(wpid)

      wait_until(fn -> Polecat.state(pid).status == :failed end)
      assert Polecat.state(pid).meta.failure_reason == {:mr_closed, "!2"}
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "approved + auto_merge merges then completes" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!3", [%{status: :open, approved: true}])

      start_warden(pid, bead_id, "!3", auto_merge: true)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert StubMerger.merge_count("!3") == 1
    end

    test "approved without auto_merge parks until a later poll sees merged" do
      {pid, bead_id} = running_polecat()
      # First poll: approved but not merged -> stay parked (no merge call).
      # Second poll: merged -> complete.
      StubMerger.queue_get("!4", [%{status: :open, approved: true}, %{status: :merged}])

      start_warden(pid, bead_id, "!4", auto_merge: false)

      wait_until(fn -> Polecat.state(pid).status == :completed end)
      assert StubMerger.merge_count("!4") == 0
    end

    test "records the last merger status + checked timestamp on the polecat" do
      {pid, bead_id} = running_polecat()
      # Stay pending so the warden keeps polling and we can observe the record.
      StubMerger.queue_get("!5", [%{status: :open, approved: false}])

      start_warden(pid, bead_id, "!5", [])

      wait_until(fn ->
        meta = Polecat.state(pid).meta

        Map.get(meta, :last_merger_status) == %{status: :open, approved: false} and
          match?(%DateTime{}, Map.get(meta, :last_checked_at))
      end)
    end
  end

  describe "lifecycle" do
    test "stops when the watched polecat dies" do
      {pid, bead_id} = running_polecat()
      StubMerger.queue_get("!6", [%{status: :open, approved: false}])

      wpid = start_warden(pid, bead_id, "!6", [])
      ref = Process.monitor(wpid)

      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 1_000
    end

    test "init returns :ignore when the polecat is already gone" do
      assert Warden.start_link(
               bead_id: "gone",
               polecat: "no-such-bead",
               mr_ref: "!7",
               adapter: StubMerger
             ) == :ignore
    end
  end
end
