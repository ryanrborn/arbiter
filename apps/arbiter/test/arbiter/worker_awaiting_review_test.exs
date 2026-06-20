defmodule Arbiter.WorkerAwaitingReviewTest do
  # async: false — shares the singleton Worker registry/supervisor + the
  # named StubMerger Agent.
  use ExUnit.Case, async: false

  alias Arbiter.Worker
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_task_id, do: "ar-test-#{System.unique_integer([:positive])}"

  defp running_worker(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, new_task_id())
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, task_id}
  end

  # Park well into the future so the auto-started Watchdog doesn't poll while we
  # assert on the transition itself.
  @parked [interval_ms: 1_000_000, initial_delay_ms: 1_000_000]

  defp open_opts(extra), do: Map.merge(%{adapter: StubMerger, workspace: nil}, Map.new(extra))

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

  describe "open_mr/5" do
    test "transitions :running -> :awaiting_review and stores mr_ref + merger_url" do
      {pid, _task_id} = running_worker()
      StubMerger.next_open_ref("!42")

      assert {:ok, "!42"} =
               Worker.open_mr(pid, "feature/x", "Add x", "desc", open_opts(@parked))

      snap = Worker.state(pid)
      assert snap.status == :awaiting_review
      assert snap.mr_ref == "!42"
      assert snap.merger_url == "https://stub.example/mr/!42"
      assert snap.meta.mr_ref == "!42"
    end

    test "forwards branch/title/description and opts to the adapter" do
      {pid, _task_id} = running_worker()

      assert {:ok, _} =
               Worker.open_mr(
                 pid,
                 "feature/y",
                 "Title Y",
                 "Body Y",
                 open_opts(Keyword.merge(@parked, target_branch: "develop", labels: ["wip"]))
               )

      open = StubMerger.last_open()
      assert open.branch == "feature/y"
      assert open.title == "Title Y"
      assert open.description == "Body Y"
      assert open.opts.target_branch == "develop"
      assert open.opts.labels == ["wip"]
    end

    test "is rejected from :idle" do
      task_id = new_task_id()
      {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:error, {:invalid_transition, :idle, :awaiting_review}} =
               Worker.open_mr(pid, "feature/z", "Z", "", open_opts(@parked))

      assert Worker.state(pid).status == :idle
    end

    test "an adapter open error leaves the worker :running" do
      {pid, _task_id} = running_worker()

      assert {:error, :no_workspace} =
               Worker.open_mr(pid, "feature/q", "Q", "", %{})

      assert Worker.state(pid).status == :running
    end

    test "end-to-end: a merged MR drives the worker to :completed via the watchdog" do
      {pid, _task_id} = running_worker()
      StubMerger.next_open_ref("!7")
      StubMerger.queue_get("!7", [%{status: :merged}])

      assert {:ok, "!7"} =
               Worker.open_mr(
                 pid,
                 "feature/done",
                 "Done",
                 "",
                 open_opts(interval_ms: 20, initial_delay_ms: 0)
               )

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
    end
  end

  describe "via_review_gate: a ReviewGate-approved MR merges without forge approval (bd-66ey1o)" do
    # Before bd-66ey1o the Watchdog waited on `approved: true` from the adapter's
    # get/1 even when the worker had just been told the gate had approved. For
    # hosted-forge adapters that approval is never posted (the ReviewGate is in-
    # process), so the worker hung at :awaiting_review forever. With the
    # `via_review_gate: true` flag the Watchdog treats any non-terminal poll as
    # `:approved` and force-auto-merges on its first poll.
    test "open_mr with via_review_gate: true drives worker to :completed without forge approval" do
      {pid, _task_id} = running_worker()
      StubMerger.next_open_ref("!99")
      # No queue_get → StubMerger.get/1 returns %{status: :open, approved: false}
      # forever (the exact "hosted-forge with no approval" case).

      assert {:ok, "!99"} =
               Worker.open_mr(
                 pid,
                 "feature/trib",
                 "ReviewGate-approved merge",
                 "",
                 open_opts(via_review_gate: true, interval_ms: 20, initial_delay_ms: 0)
               )

      wait_until(fn -> Worker.state(pid).status == :completed end)
      assert Worker.state(pid).meta.result == :merged
      # The Watchdog must have called the adapter's merge/1 — that's the whole
      # point of via_review_gate: don't just wait for a human, actually merge.
      assert StubMerger.merge_count("!99") >= 1
    end

    test "without via_review_gate, the same scenario reproduces the silent hang" do
      # Regression characterization: with the flag absent and no GitHub-side
      # approval forthcoming, the worker stays parked. The watchdog (added in
      # the same fix) will eventually escalate — see watchdog_test — but in the
      # window before that fires we can prove the worker does NOT auto-merge,
      # which is exactly the bug the via_review_gate flag closes.
      {pid, _task_id} = running_worker()
      StubMerger.next_open_ref("!100")

      assert {:ok, "!100"} =
               Worker.open_mr(
                 pid,
                 "feature/no-trib",
                 "Unapproved",
                 "",
                 open_opts(
                   via_review_gate: false,
                   auto_merge: true,
                   interval_ms: 20,
                   initial_delay_ms: 0,
                   max_polls: 1_000
                 )
               )

      # Let the Watchdog poll a few times.
      Process.sleep(120)
      assert Worker.state(pid).status == :awaiting_review
      assert StubMerger.merge_count("!100") == 0
    end
  end

  describe "arb-done guard while awaiting review" do
    test "a late 'arb done' does NOT complete a worker parked for review" do
      {pid, _task_id} = running_worker()
      assert {:ok, _} = Worker.open_mr(pid, "feature/g", "G", "", open_opts(@parked))
      assert Worker.state(pid).status == :awaiting_review

      # Simulate the ClaudeSession completion marker arriving after the MR
      # was opened. The review gate, not stdout, owns completion now.
      send(pid, {:__claude_session_done__, "arb done"})
      Process.sleep(30)

      assert Worker.state(pid).status == :awaiting_review
    end
  end

  describe "record_merger_status/2" do
    test "stores the result and a checked-at timestamp in meta" do
      {pid, _task_id} = running_worker()
      :ok = Worker.record_merger_status(pid, %{status: :open, approved: true})

      meta = Worker.state(pid).meta
      assert meta.last_merger_status == %{status: :open, approved: true}
      assert %DateTime{} = meta.last_checked_at
    end
  end
end
