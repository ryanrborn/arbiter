defmodule Arbiter.Board.AutopilotDeferredResumeTest do
  @moduledoc """
  bd-92mx1m acceptance 3: an automatic resume of a task that released its slot,
  arriving at a full cap, is **deferred** — not failed, not bypassed — and
  starts as soon as a slot frees, **ahead of** any new Ready dispatch.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  defp board(slots_free, promote \\ "bd-ready") do
    %{
      ready: [%{id: "bd-ready", state: :next, reason: "next up", card: %{id: "bd-ready"}}],
      running: [],
      waiting: [],
      closed_today: [],
      promote: if(slots_free > 0, do: promote),
      slots_total: 1,
      slots_free: slots_free,
      quota: :ok,
      paused: false,
      now: DateTime.utc_now()
    }
  end

  # `free` is an Agent holding the board's slots_free, so a test can "free a
  # slot" between passes the way a merge would.
  defp start(opts) do
    test = self()
    {:ok, free} = Agent.start_link(fn -> Keyword.get(opts, :slots_free, 0) end)

    defaults = [
      name: nil,
      interval_ms: :never,
      # Only `tick/2` drives a pass unless a test opts into the reactive one.
      debounce_ms: 60_000,
      topics: [],
      follow_up: false,
      paused: false,
      snapshot: fn _ -> board(Agent.get(free, & &1)) end,
      dispatch: fn id ->
        send(test, {:dispatched, id})
        {:ok, %{task_id: id}}
      end,
      resume: fn task_id, kind, opts ->
        send(test, {:resumed, task_id, kind, opts})
        {:ok, %{task_id: task_id}}
      end,
      escalate: fn id, reason, n -> send(test, {:escalated, id, reason, n}) end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, Keyword.drop(opts, [:slots_free])))
    {pid, free}
  end

  defp free_slot(free), do: Agent.update(free, fn _ -> 1 end)

  test "a deferred resume waits while the cap is full, and nothing Ready jumps it" do
    {pid, _free} = start(slots_free: 0)

    assert :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, revise_feedback: "fix it")
    assert :idle = Autopilot.tick(pid)

    refute_received {:resumed, _, _, _}
    refute_received {:dispatched, _}
    assert Autopilot.status(pid).deferred_resumes == ["bd-parked"]
  end

  test "it starts when a slot frees, ahead of the Ready card, with the caller's options" do
    {pid, free} = start(slots_free: 0)
    :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, revise_feedback: "fix it")

    free_slot(free)
    assert {:resumed, "bd-parked"} = Autopilot.tick(pid)

    assert_received {:resumed, "bd-parked", :resume, opts}
    assert opts[:revise_feedback] == "fix it"
    # The scheduler admitted it into the free slot; the resume must not re-ask.
    assert opts[:slot_admitted] == true
    refute_received {:dispatched, _}
    assert Autopilot.status(pid).deferred_resumes == []

    # The Ready card goes on the next pass, not before.
    assert {:ok, "bd-ready"} = Autopilot.tick(pid)
    assert_received {:dispatched, "bd-ready"}
  end

  test "deferred resumes drain in arrival order, and a re-deferral keeps its place" do
    {pid, free} = start(slots_free: 0)
    :ok = Autopilot.defer_resume(pid, "bd-first", :resume, attempt: 1)
    :ok = Autopilot.defer_resume(pid, "bd-second", :resume_session, [])
    :ok = Autopilot.defer_resume(pid, "bd-first", :resume, attempt: 2)

    assert Autopilot.status(pid).deferred_resumes == ["bd-first", "bd-second"]

    free_slot(free)
    assert {:resumed, "bd-first"} = Autopilot.tick(pid)
    assert_received {:resumed, "bd-first", :resume, opts}
    assert opts[:attempt] == 2

    assert {:resumed, "bd-second"} = Autopilot.tick(pid)
    assert_received {:resumed, "bd-second", :resume_session, _}
  end

  # A pause stops *new* board dispatches only (`Arbiter.Board.Drain`): a
  # deferred resume is work already in progress, so it still drains.
  test "a paused scheduler still starts a deferred resume, but promotes nothing Ready" do
    {pid, free} = start(slots_free: 0, paused: true)
    :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])

    assert :paused = Autopilot.tick(pid)
    free_slot(free)
    assert {:resumed, "bd-parked"} = Autopilot.tick(pid)
    assert :paused = Autopilot.tick(pid)
    refute_received {:dispatched, _}
  end

  test "deferring schedules a pass by itself, so a free slot is taken without a tick" do
    {pid, _free} = start(slots_free: 1, debounce_ms: 5)
    :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])

    assert_receive {:resumed, "bd-parked", :resume, _}
  end

  test "a replay that fails for a lasting reason is escalated and dropped, not retried" do
    {pid, free} = start(slots_free: 0, resume: fn _, _, _ -> {:error, :no_outpost} end)

    :ok = Autopilot.defer_resume(pid, "bd-gone", :resume, [])
    free_slot(free)

    assert {:error, :no_outpost} = Autopilot.tick(pid)
    assert_received {:escalated, "bd-gone", {:deferred_resume_failed, :no_outpost}, 1}
    assert Autopilot.status(pid).deferred_resumes == []
  end

  test "a replay that finds the task already resumed or closed is dropped quietly" do
    {pid, free} =
      start(slots_free: 0, resume: fn _, _, _ -> {:error, {:worker_active, :running}} end)

    :ok = Autopilot.defer_resume(pid, "bd-raced", :resume, [])
    free_slot(free)

    assert {:error, {:worker_active, :running}} = Autopilot.tick(pid)
    refute_received {:escalated, _, _, _}
    assert Autopilot.status(pid).deferred_resumes == []
  end

  # A task parking for a human frees its slot without a worker_done /
  # worker_failed event — only a `worker_phase` says so. That is worth a pass
  # exactly while a deferred resume is waiting for the slot.
  test "a slot-releasing phase change asks for a pass only while a resume waits" do
    {pid, _free} = start(slots_free: 0)
    released = {:event, %{topic: "worker_phase", phase: "waiting_on_you"}}

    send(pid, released)
    assert :sys.get_state(pid).plan_timer == nil

    :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
    # Consume the pass the deferral itself asked for.
    send(pid, :run_plan)
    assert :sys.get_state(pid).plan_timer == nil

    send(pid, {:event, %{topic: "worker_phase", phase: "implementing"}})
    assert :sys.get_state(pid).plan_timer == nil

    send(pid, released)
    assert :sys.get_state(pid).plan_timer != nil
  end

  test "defer_resume/4 against a scheduler that is not running refuses" do
    assert {:error, :not_running} =
             Autopilot.defer_resume(:no_such_autopilot, "bd-x", :resume, [])
  end
end
