defmodule Arbiter.Tasks.SlotGateTaskTest do
  @moduledoc """
  bd-45pwo1: a slot belongs to the **task**, from dispatch until its PR
  merges (or it closes, fails, stops, or parks for a human) — not to
  whichever agent happens to be live for it right now. `occupied_tasks/2`
  counts one slot per task whose `Arbiter.Worker.Phase` is not released,
  reading `:phase` off an already-annotated worker list
  (`Arbiter.Worker.Phase.annotate/1`) so it never drifts from what the board
  renders.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Worker.Phase

  defp author(task_id, status, attrs) do
    Map.merge(
      %{task_id: task_id, registry_key: task_id, status: status, role: nil, meta: %{}},
      attrs
    )
  end

  defp reviewer(of, attrs) do
    Map.merge(
      author(of <> "#review", :running, %{role: :reviewer, meta: %{role: :reviewer, reviews: of}}),
      attrs
    )
  end

  defp implementer(of, attrs) do
    Map.merge(
      author(of <> "#review#impl1", :running, %{
        role: :implementer,
        meta: %{role: :implementer, revises: of}
      }),
      attrs
    )
  end

  defp fix_pass(of, attrs) do
    Map.merge(
      author(of, :running, %{
        registry_key: of <> ":fixpass",
        role: :fix_pass,
        meta: %{role: :fix_pass}
      }),
      attrs
    )
  end

  defp conflict(of, attrs) do
    Map.merge(
      author(of, :running, %{
        registry_key: of <> ":conflict",
        role: :conflict_resolver,
        meta: %{role: :conflict_resolver}
      }),
      attrs
    )
  end

  describe "task_occupies_slot?/1" do
    test "every pre-merge phase holds the slot" do
      for phase <- [
            :implementing,
            :in_review,
            :addressing_review,
            :fixing_ci,
            :resolving_conflict,
            :waiting_ci_merge,
            :handing_off
          ] do
        assert SlotGate.task_occupies_slot?(phase), "#{phase} should hold the task's slot"
      end
    end

    test "done and human-parked release the slot" do
      refute SlotGate.task_occupies_slot?(:done)
      refute SlotGate.task_occupies_slot?(:waiting_on_you)
    end
  end

  describe "occupied_tasks/2 (:agents basis)" do
    test "a task with a live main agent holds one slot" do
      workers = Phase.annotate([author("bd-1", :running, %{agent_live: true})])
      assert SlotGate.occupied_tasks(workers, :agents) == 1
    end

    test "a task between rounds with no live agent still holds its slot" do
      # The evidence in the ticket: a task waiting between ReviewGate rounds
      # held no slot under #1969's agent-liveness rule, letting a third task
      # dispatch on top of two already in flight.
      workers = Phase.annotate([author("bd-1", :awaiting_review_gate, %{agent_live: false})])
      assert SlotGate.occupied_tasks(workers, :agents) == 1
    end

    test "waiting on CI / merge still holds the slot" do
      workers = Phase.annotate([author("bd-1", :awaiting_review, %{agent_live: false})])
      assert SlotGate.occupied_tasks(workers, :agents) == 1
    end

    test "a reviewer, implementer, fix pass and conflict resolver each fold into the author's one slot" do
      workers =
        Phase.annotate([
          author("bd-1", :awaiting_review_gate, %{agent_live: false}),
          reviewer("bd-1", %{agent_live: true})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 1

      workers =
        Phase.annotate([
          author("bd-2", :awaiting_review_gate, %{agent_live: false}),
          implementer("bd-2", %{agent_live: true})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 1

      workers =
        Phase.annotate([
          author("bd-3", :awaiting_review, %{agent_live: false}),
          fix_pass("bd-3", %{agent_live: true})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 1

      workers =
        Phase.annotate([
          author("bd-4", :awaiting_review, %{agent_live: false}),
          conflict("bd-4", %{agent_live: true})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 1
    end

    test "two tasks in flight plus a live round is still exactly two slots" do
      workers =
        Phase.annotate([
          author("bd-1", :awaiting_review_gate, %{agent_live: false}),
          reviewer("bd-1", %{agent_live: true}),
          author("bd-2", :running, %{agent_live: true})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 2
    end

    test "a merged task (:completed) releases its slot" do
      workers = Phase.annotate([author("bd-1", :completed, %{agent_live: false})])
      assert SlotGate.occupied_tasks(workers, :agents) == 0
    end

    test "a task parked on a human (:awaiting or :failed) releases its slot" do
      workers = Phase.annotate([author("bd-1", :awaiting, %{agent_live: false})])
      assert SlotGate.occupied_tasks(workers, :agents) == 0

      workers = Phase.annotate([author("bd-2", :failed, %{agent_live: false})])
      assert SlotGate.occupied_tasks(workers, :agents) == 0
    end

    test "three tasks against a cap of two are correctly over" do
      workers =
        Phase.annotate([
          author("bd-1", :running, %{agent_live: true}),
          author("bd-2", :awaiting_review_gate, %{agent_live: false}),
          author("bd-3", :awaiting_review, %{agent_live: false})
        ])

      assert SlotGate.occupied_tasks(workers, :agents) == 3
      assert SlotGate.task_free(2, workers, :agents) == 0
    end
  end

  describe "task_free/3" do
    test "never reports a negative number of slots" do
      workers =
        Phase.annotate(for i <- 1..5, do: author("bd-#{i}", :running, %{agent_live: true}))

      assert SlotGate.task_free(2, workers, :agents) == 0
      assert SlotGate.task_free(8, workers, :agents) == 3
    end
  end
end
