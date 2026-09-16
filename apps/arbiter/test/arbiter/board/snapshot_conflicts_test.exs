defmodule Arbiter.Board.SnapshotConflictsTest do
  @moduledoc """
  bd-6bax7s: the board treats `:conflicts_with` as a mutex against anything in
  flight, and says so on the card.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-09-16 17:41:52Z]

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

  defp worker(task_id, status, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: task_id,
        status: status,
        workspace_id: "ws-1",
        current_step: :implement,
        started_at: @now,
        step_started_at: @now,
        mr_ref: nil,
        merger_url: nil,
        meta: %{}
      },
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
          conflicts_with: [],
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

  defp entry(board, id), do: Enum.find(board.ready, &(&1.id == id))

  describe "a counterpart with a live worker" do
    test "holds the Ready card back and names the counterpart and its state" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7", :running)],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == nil

      assert %{state: :blocked, reason: "blocked — conflicts with bd-7 (running)"} =
               entry(board, "bd-1")
    end

    test "the edge is honoured in the direction it was not stored in" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7", :running)],
          # stored bd-7 → bd-1; bd-1 is the Ready card and must still be held.
          conflicts_with: [{"bd-7", "bd-1"}]
        )

      assert board.promote == nil
      assert %{state: :blocked, reason: "blocked — conflicts with bd-7 (running)"} = entry(board, "bd-1")
    end

    for {status, state} <- [
          idle: "running",
          running: "running",
          resuming: "resuming",
          awaiting: "awaiting input",
          awaiting_review_gate: "in review",
          awaiting_review: "awaiting review"
        ] do
      test "a #{status} counterpart is in flight (#{state})" do
        board =
          derive(
            issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
            workers: [worker("bd-7", unquote(status))],
            conflicts_with: [{"bd-1", "bd-7"}]
          )

        assert board.promote == nil

        assert %{reason: "blocked — conflicts with bd-7 (#{unquote(state)})"} =
                 entry(board, "bd-1")
      end
    end

    test "a reviewer's own worker folds onto the author it reviews" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [
            worker("bd-7", :awaiting_review_gate),
            worker("bd-7#review", :running, %{meta: %{role: :reviewer, reviews: "bd-7"}})
          ],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == nil
      assert %{reason: "blocked — conflicts with bd-7 (in review)"} = entry(board, "bd-1")
    end

    test "a fix-pass implementer keeps the mutex even with no author worker left" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7#impl2", :running, %{meta: %{role: :implementer, revises: "bd-7"}})],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == nil
      assert %{reason: "blocked — conflicts with bd-7 (fix pass)"} = entry(board, "bd-1")
    end
  end

  describe "a counterpart that is no longer in flight" do
    test "a closed counterpart releases the card" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :closed, closed_at: @now})],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == "bd-1"
    end

    test "a merged counterpart parked at awaiting_verification releases the card" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :awaiting_verification})],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == "bd-1"
    end

    test "a parked (:failed) counterpart releases the card" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7", :failed)],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == "bd-1"
    end

    test "an orphaned counterpart — in_progress, no live worker — releases the card" do
      stale = DateTime.add(@now, -3600, :second)

      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress, updated_at: stale})],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == "bd-1"
    end

    test "a counterpart still mid-dispatch holds the card" do
      # Dispatch flips the issue to :in_progress seconds before the worker
      # registers; inside the orphan grace that reads as in flight, not gone.
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert board.promote == nil
      assert %{reason: "blocked — conflicts with bd-7 (dispatching)"} = entry(board, "bd-1")
    end
  end

  describe "the bd-1780 incident" do
    test "two conflicting Ready cards promoted seconds apart dispatch one at a time" do
      issues = [
        issue("bd-1c4pg3", %{priority: 1, title: "bind address"}),
        issue("bd-7srf5d", %{priority: 2, title: "remote-access docs"})
      ]

      first = derive(issues: issues, conflicts_with: [{"bd-7srf5d", "bd-1c4pg3"}])

      assert first.promote == "bd-1c4pg3"

      assert %{state: :blocked, reason: "blocked — conflicts with bd-1c4pg3 (dispatching)"} =
               entry(first, "bd-7srf5d")

      # …and on the next tick, with bd-1c4pg3 actually running, it still waits.
      second =
        derive(
          issues: [
            issue("bd-1c4pg3", %{priority: 1, status: :in_progress}),
            issue("bd-7srf5d", %{priority: 2})
          ],
          workers: [worker("bd-1c4pg3", :running)],
          conflicts_with: [{"bd-7srf5d", "bd-1c4pg3"}]
        )

      assert second.promote == nil
      assert %{reason: "blocked — conflicts with bd-1c4pg3 (running)"} = entry(second, "bd-7srf5d")

      # …and once it closes, the second one goes.
      third =
        derive(
          issues: [
            issue("bd-1c4pg3", %{priority: 1, status: :closed, closed_at: @now}),
            issue("bd-7srf5d", %{priority: 2})
          ],
          conflicts_with: [{"bd-7srf5d", "bd-1c4pg3"}]
        )

      assert third.promote == "bd-7srf5d"
    end
  end

  describe "non-gating edges" do
    test "a parent_of or relates_to edge never holds a card back" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7", :running)],
          parent_of: [{"bd-7", "bd-1"}],
          conflicts_with: []
        )

      assert board.promote == "bd-1"
    end
  end

  describe "an open dependency still outranks a conflict" do
    test "the waiting-on reason wins when both hold" do
      board =
        derive(
          issues: [issue("bd-1"), issue("bd-7", %{status: :in_progress})],
          workers: [worker("bd-7", :running)],
          blocked_by: %{"bd-1" => ["bd-9"]},
          conflicts_with: [{"bd-1", "bd-7"}]
        )

      assert %{reason: "blocked — waiting on bd-9"} = entry(board, "bd-1")
    end
  end
end
