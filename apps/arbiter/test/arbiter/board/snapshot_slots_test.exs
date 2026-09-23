defmodule Arbiter.Board.SnapshotSlotsTest do
  @moduledoc """
  bd-aw2cyt: a slot is a live agent session in any role, not an author record
  in a live status, and a card names the phase it is actually in.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-09-16 22:25:00Z]

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        status: :open,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        refined: true,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      attrs
    )
  end

  defp author(task_id, status, attrs) do
    Map.merge(
      %{
        task_id: task_id,
        registry_key: task_id,
        status: status,
        role: nil,
        workspace_id: "ws-1",
        current_step: :implement,
        started_at: @now,
        step_started_at: @now,
        mr_ref: nil,
        merger_url: nil,
        agent_live: false,
        meta: %{}
      },
      attrs
    )
  end

  defp reviewer(of, attrs) do
    Map.merge(
      author(of <> "#review", :running, %{
        role: :reviewer,
        meta: %{role: :reviewer, reviews: of}
      }),
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

  defp derive(overrides) do
    Snapshot.derive(
      Map.merge(
        %{
          issues: [],
          workers: [],
          blocked_by: %{},
          changed_files: %{},
          now: @now,
          slots_total: 4,
          quota: :ok,
          paused: false
        },
        Map.new(overrides)
      )
    )
  end

  defp card(board, column, id) do
    board |> Map.fetch!(column) |> Enum.find(&(&1.id == id))
  end

  describe "agents_live is live agents, not records" do
    test "an author record whose agent has exited holds no live-agent count" do
      # vs-8iqckq on 2026-09-16: `status=running`, no process anywhere.
      board = derive(slots_total: 2, workers: [author("bd-1", :running, %{agent_live: false})])

      assert board.agents_live == 0
    end

    test "every live role takes a live-agent count of its own" do
      workers = [
        author("bd-1", :awaiting_review_gate, %{agent_live: false}),
        reviewer("bd-1", %{agent_live: true}),
        author("bd-2", :awaiting_review, %{agent_live: false}),
        fix_pass("bd-2", %{agent_live: true}),
        author("bd-3", :running, %{agent_live: true})
      ]

      board = derive(slots_total: 5, workers: workers)

      assert board.agents_live == 3
      assert board.slots_used == 3
      assert board.slots_free == 2
    end

    test "an implementer round and a conflict resolver each count, but fold into their author's one slot" do
      workers = [
        author("bd-1", :awaiting_review_gate, %{agent_live: false}),
        implementer("bd-1", %{agent_live: true}),
        author("bd-2", :awaiting_review, %{agent_live: false}),
        conflict("bd-2", %{agent_live: true})
      ]

      board = derive(slots_total: 4, workers: workers)

      assert board.agents_live == 2
      # Two agent sessions, but still only two tasks — bd-45pwo1's rule is
      # exactly one slot per task regardless of how many subordinate rounds
      # are live for it.
      assert board.slots_used == 2
    end
  end

  describe "bd-45pwo1: a slot belongs to the task, not to whichever agent is live" do
    test "a task between ReviewGate rounds with no live agent still holds its slot" do
      # The exact shape the ticket names: no reviewer/implementer/fix-pass
      # currently live, but the task is not done and nobody parked it for a
      # human, so it must still occupy its one slot.
      board = derive(slots_total: 2, workers: [author("bd-1", :running, %{agent_live: false})])

      assert board.agents_live == 0
      assert board.slots_used == 1
      assert board.slots_free == 1
    end

    test "waiting on CI / merge still holds the slot" do
      board =
        derive(slots_total: 2, workers: [author("bd-1", :awaiting_review, %{agent_live: false})])

      assert board.slots_used == 1
      assert board.slots_free == 1
    end

    test "a question or a parked failure (:waiting_on_you) releases the slot" do
      board = derive(slots_total: 2, workers: [author("bd-1", :awaiting, %{agent_live: false})])

      assert board.slots_used == 0
      assert board.slots_free == 2

      board = derive(slots_total: 2, workers: [author("bd-1", :failed, %{agent_live: false})])

      assert board.slots_used == 0
      assert board.slots_free == 2
    end

    test "a merged task (:completed) releases the slot" do
      board = derive(slots_total: 2, workers: [author("bd-1", :completed, %{agent_live: false})])

      assert board.slots_used == 0
      assert board.slots_free == 2
    end

    test "rounds above the cap never report negative free slots" do
      workers = [
        author("bd-1", :awaiting_review_gate, %{agent_live: false}),
        reviewer("bd-1", %{agent_live: true}),
        author("bd-2", :running, %{agent_live: true}),
        author("bd-3", :running, %{agent_live: true})
      ]

      board = derive(slots_total: 1, workers: workers)

      assert board.agents_live == 3
      assert board.slots_used == 3
      assert board.slots_free == 0
    end

    test "a cap-full board promotes nothing new" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-ready")],
          workers: [author("bd-1", :running, %{agent_live: true})]
        )

      assert board.slots_free == 0
      assert board.promote == nil
    end

    test "a task waiting on CI / merge still occupies the cap, so nothing new promotes" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-ready")],
          workers: [author("bd-1", :awaiting_review, %{agent_live: false})]
        )

      assert board.slots_free == 0
      assert board.promote == nil
    end

    test "a merged task frees its slot and promotes the next Ready card" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-ready")],
          workers: [author("bd-1", :completed, %{agent_live: false})]
        )

      assert board.slots_free == 1
      assert board.promote == "bd-ready"
    end
  end

  describe "slot_basis" do
    @tag :slot_basis
    test ":issues restores the pre-bd-aw2cyt record-based counting" do
      workers = [
        author("bd-1", :running, %{agent_live: false}),
        author("bd-2", :awaiting, %{agent_live: false}),
        reviewer("bd-1", %{agent_live: true})
      ]

      agents = derive(slots_total: 4, workers: workers, slot_basis: :agents)
      issues = derive(slots_total: 4, workers: workers, slot_basis: :issues)

      assert agents.slots_free == 3
      assert issues.slots_free == 2
    end
  end

  describe "phase on the card" do
    test "a live main agent is :implementing" do
      board = derive(workers: [author("bd-1", :running, %{agent_live: true})])

      assert %{phase: :implementing, agent_live: true} = card(board, :running, "bd-1")
    end

    test "a live reviewer makes the author's card read :in_review" do
      board =
        derive(
          workers: [
            author("bd-1", :awaiting_review_gate, %{agent_live: false}),
            reviewer("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :in_review, agent_live: true} = card(board, :running, "bd-1")
    end

    test "a live implementer round reads :addressing_review" do
      board =
        derive(
          workers: [
            author("bd-1", :awaiting_review_gate, %{agent_live: false}),
            implementer("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :addressing_review} = card(board, :running, "bd-1")
    end

    test "an open MR with nothing running reads :waiting_ci_merge, and no live agent" do
      board = derive(workers: [author("bd-1", :awaiting_review, %{agent_live: false})])

      assert %{phase: :waiting_ci_merge, agent_live: false} = card(board, :waiting, "bd-1")
    end

    test "a live CI fix pass reads :fixing_ci on the waiting card" do
      board =
        derive(
          workers: [
            author("bd-1", :awaiting_review, %{agent_live: false}),
            fix_pass("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :fixing_ci, agent_live: true} = card(board, :waiting, "bd-1")
    end

    test "a question reads :waiting_on_you" do
      board = derive(workers: [author("bd-1", :awaiting, %{agent_live: false})])

      assert %{phase: :waiting_on_you, agent_live: false} = card(board, :waiting, "bd-1")
    end

    test "a running record with no agent is visibly distinguished, not called running" do
      board = derive(workers: [author("bd-1", :running, %{agent_live: false})])

      c = card(board, :running, "bd-1")
      assert c.agent_live == false
      refute c.phase == :implementing
    end
  end
end
