defmodule Arbiter.Worker.PhaseEventsTest do
  @moduledoc """
  bd-aw2cyt: the `/events` stream carries the worker's phase — a new
  `worker_phase` event on each transition, and `phase` + `status` on the
  existing `worker_done` / `worker_failed` payloads.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "phase-evt-#{System.unique_integer([:positive])}",
        prefix: "pev#{System.unique_integer([:positive])}"
      })

    {:ok, task} = Ash.create(Issue, %{title: "phase event target", workspace_id: ws.id})

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task.id, :normal) end)

    %{ws: ws, task: task, pid: pid}
  end

  defp await_event(topic, timeout \\ 1_000) do
    receive do
      {:event, %{topic: ^topic} = e} -> e
      {:event, _other} -> await_event(topic, timeout)
    after
      timeout -> flunk("no #{topic} event within #{timeout}ms")
    end
  end

  test "worker_phase is emitted when the worker's phase changes", %{pid: pid, task: task} do
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.await(pid, "which base branch?")

    event = await_event("worker_phase")

    assert event.task_id == task.id
    assert event.phase == "waiting_on_you"
    assert event.status == "awaiting"
    assert event.agent_live == false
  end

  test "worker_phase is not emitted when the phase did not change", %{pid: pid} do
    # `:idle` and `:running` with no agent are both `:handing_off` — the
    # record moved, the work did not. An event stream should not narrate a
    # non-event.
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.advance(pid, :implement)

    refute_receive {:event, %{topic: "worker_phase"}}, 300
  end

  test "parking at :awaiting_review announces waiting_ci_merge", %{pid: pid, task: task} do
    # The author's agent is long gone by the time the MR opens: the record says
    # :awaiting_review, the honest phase is "waiting on CI / merge", and the
    # `worker_phase` topic has to say so — this is one of the two transitions
    # the ticket exists to surface.
    StubMerger.reset()
    StubMerger.next_open_ref("!91")

    :ok = Worker.advance(pid, :implement)

    assert {:ok, "!91"} =
             Worker.open_mr(pid, "feature/phase", "Phase", "desc", %{
               adapter: StubMerger,
               workspace: nil,
               # Park the Watchdog well past the test so it can't poll the stub
               # and complete the worker out from under the assertion.
               interval_ms: 1_000_000,
               initial_delay_ms: 1_000_000
             })

    event = await_event("worker_phase")

    assert event.task_id == task.id
    assert event.phase == "waiting_ci_merge"
    assert event.status == "awaiting_review"
    assert event.agent_live == false
  end

  test "worker_failed carries the status and phase", %{pid: pid, task: task} do
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.fail(pid, "boom")

    event = await_event("worker_failed")

    assert event.task_id == task.id
    assert event.status == "failed"
    assert event.phase == "waiting_on_you"
  end
end
