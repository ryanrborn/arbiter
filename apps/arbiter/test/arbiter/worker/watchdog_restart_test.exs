defmodule Arbiter.Worker.WatchdogRestartTest do
  @moduledoc """
  bd-8jixav: a Watchdog GenServer can die outright — crash, or fail to start
  after the MR was already opened — leaving the worker parked at
  `:awaiting_review` forever with a genuinely-open MR and nothing polling it.

  `retry_auto_resolve/1` (bd-bspakl) cannot recover this: it messages an
  *already-running* Watchdog. These cases pin `Watchdog.restart/1`, which mints
  a **fresh** Watchdog against the worker's existing MR ref without going
  through a full `worker_resume` (which would restart the review gate from
  round 1 at real cost).

  `watchdog_start_error: true` on `open_mr/5` reproduces the incident state
  exactly: MR open on the forge, worker parked, no Watchdog registered.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_workspace(config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wd-restart-ws-#{System.unique_integer([:positive])}",
        prefix: "wr",
        config: config
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "watchdog restart task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    task
  end

  defp running_worker(task, ws) do
    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "wr/repo", workspace_id: ws.id)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :implement)
    pid
  end

  # Park a worker at :awaiting_review with a real MR ref and NO Watchdog —
  # the dead-watchdog state this ticket is about.
  defp parked_without_watchdog(task, ws, mr_ref, opts \\ %{}) do
    pid = running_worker(task, ws)
    StubMerger.next_open_ref(mr_ref)

    {:ok, ^mr_ref} =
      Worker.open_mr(
        pid,
        "feature/#{mr_ref}",
        "MR #{mr_ref}",
        "desc",
        Map.merge(
          %{
            adapter: StubMerger,
            workspace: ws,
            interval_ms: 20,
            initial_delay_ms: 0,
            watchdog_start_error: true
          },
          opts
        )
      )

    assert Worker.state(pid).status == :awaiting_review
    assert Watchdog.whereis(task.id) == nil
    pid
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

  describe "restart/1" do
    test "mints a fresh Watchdog against the parked worker's existing MR ref" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr1", [%{status: :open, approved: false}])
      parked_without_watchdog(task, ws, "!wr1")

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      wpid = Watchdog.whereis(task.id)
      on_exit(fn -> if Process.alive?(wpid), do: GenServer.stop(wpid, :normal) end)

      # It is genuinely polling the *existing* MR, not a new one.
      wait_until(fn -> StubMerger.get_count("!wr1") >= 1 end)
    end

    test "the restarted Watchdog carries the task through to completion" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr2", [%{status: :merged}])
      pid = parked_without_watchdog(task, ws, "!wr2")

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> Worker.state(pid).status == :completed end)
    end

    test "refuses when a Watchdog is already running (never two live watchdogs)" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr3", [%{status: :open, approved: false}])
      parked_without_watchdog(task, ws, "!wr3")

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      wpid = Watchdog.whereis(task.id)
      on_exit(fn -> if Process.alive?(wpid), do: GenServer.stop(wpid, :normal) end)

      assert {:error, :already_running} = Watchdog.restart(task.id)
      # ...and the original is untouched.
      assert Watchdog.whereis(task.id) == wpid
    end

    test "returns :no_worker when no worker is registered for the task" do
      assert Watchdog.restart("no-such-task-#{System.unique_integer([:positive])}") ==
               {:error, :no_worker}
    end

    test "refuses a worker that isn't parked at :awaiting_review" do
      ws = new_workspace()
      task = new_task(ws)
      running_worker(task, ws)

      assert Watchdog.restart(task.id) == {:error, {:not_parked, :running}}
    end

    test "replays the via_review_gate lane recorded when the MR was opened" do
      # auto_merge on, gate-approved: the Watchdog must treat an unapproved
      # forge poll as approved and merge. A restart that lost via_review_gate
      # would park forever waiting on a forge approval the gate never posts —
      # the exact vs-3vlaqi failure mode.
      ws = new_workspace(%{"merge" => %{"auto_merge" => true}})
      task = new_task(ws)
      StubMerger.queue_get("!wr4", [%{status: :open, approved: false}])
      parked_without_watchdog(task, ws, "!wr4", %{via_review_gate: true})

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> StubMerger.merge_count("!wr4") >= 1 end)
    end

    test "recovers a Watchdog that crashed after polling had already started" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr5", [%{status: :open, approved: false}])
      parked_without_watchdog(task, ws, "!wr5")

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      first = Watchdog.whereis(task.id)

      # Simulate the incident: the Watchdog dies outright, silently.
      Process.exit(first, :kill)
      wait_until(fn -> Watchdog.whereis(task.id) == nil end)

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      second = Watchdog.whereis(task.id)
      on_exit(fn -> if Process.alive?(second), do: GenServer.stop(second, :normal) end)

      refute second == first
    end
  end
end
