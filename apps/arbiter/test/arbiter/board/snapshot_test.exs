defmodule Arbiter.Board.SnapshotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-08-22 12:00:00Z]
  @yesterday ~U[2026-08-21 23:00:00Z]

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
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now
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

  defp ids(cards), do: Enum.map(cards, & &1.id)

  describe "ready column" do
    test "holds open issues that have no live worker, highest priority first" do
      board =
        derive(
          issues: [
            issue("bd-a", %{priority: 3}),
            issue("bd-b", %{priority: 1}),
            issue("bd-c", %{priority: 1, created_at: @yesterday})
          ]
        )

      assert ids(board.ready) == ["bd-c", "bd-b", "bd-a"]
    end

    test "an open issue with a live worker belongs to Running, not Ready" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          workers: [worker("bd-a", :running)]
        )

      assert ids(board.ready) == ["bd-b"]
      assert ids(board.running) == ["bd-a"]
    end

    test "epics are not dispatchable work and never queue" do
      board = derive(issues: [issue("bd-a", %{issue_type: :epic}), issue("bd-b")])

      assert ids(board.ready) == ["bd-b"]
    end

    test "each card carries the scheduler's state and one-line reason" do
      board = derive(issues: [issue("bd-a"), issue("bd-b")])

      assert [
               %{id: "bd-a", state: :next, reason: "next up — dispatching..."},
               %{id: "bd-b", state: :queued, reason: "1 ahead in queue"}
             ] = board.ready
    end

    test "an open gating dependency surfaces as the card's reason" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-z"}, _] = board.ready
      assert board.promote == "bd-b"
    end

    test "file overlap with an in-flight worker holds the card" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-b")
          ],
          workers: [worker("bd-run", :running)],
          changed_files: %{"bd-run" => ["lib/board.ex"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: reason}, _] = board.ready
      assert reason == "blocked — lib/board.ex in flight on bd-run"
    end

    test "a running worker's own issue text counts as in-flight scope" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-run", %{status: :in_progress, description: "Touches `lib/board.ex` too."})
          ],
          workers: [worker("bd-run", :running)]
        )

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — lib/board.ex in flight on bd-run"}] =
               board.ready
    end
  end

  describe "slots" do
    test "every worker holding a subprocess consumes a slot" do
      board =
        derive(
          slots_total: 3,
          workers: [worker("bd-1", :running), worker("bd-2", :awaiting_review_gate)]
        )

      assert board.slots_total == 3
      assert board.slots_free == 1
    end

    test "a worker parked on its merge request is not holding a slot" do
      board = derive(slots_total: 2, workers: [worker("bd-1", :awaiting_review)])

      assert board.slots_free == 2
    end

    test "no free slot holds the queue and says so" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-a")],
          workers: [worker("bd-1", :running)]
        )

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — no free worker slot"}] = board.ready
    end
  end

  describe "running column" do
    test "shows what the worker is doing right now" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [
            worker("bd-a", :running, %{
              current_step: :implement,
              meta: %{activity: "edit · scheduler.ex"}
            })
          ]
        )

      assert [%{id: "bd-a", title: "Task bd-a", step: :implement, activity: "edit · scheduler.ex"}] =
               board.running
    end

    test "a worker under review is still running, not waiting on you" do
      board = derive(workers: [worker("bd-a", :awaiting_review_gate)])

      assert [%{id: "bd-a", activity: "in review"}] = board.running
      assert board.needs_you == []
    end

    test "reviewer workers fold into the author's card instead of queueing twice" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review_gate),
            worker("bd-a#review", :running, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert ids(board.running) == ["bd-a"]
    end
  end

  describe "needs you column" do
    test "collects failed and human-awaiting workers with why they stopped" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            }),
            worker("bd-b", :awaiting, %{meta: %{await_reason: "needs a decision"}}),
            worker("bd-c", :running)
          ]
        )

      assert ids(board.needs_you) == ["bd-a", "bd-b"]
      assert [%{reason: "review rejected"}, %{reason: "needs a decision"}] = board.needs_you
    end
  end

  describe "merge queue column" do
    test "collects workers parked on an open merge request, longest wait first" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{
              mr_ref: "!42",
              step_started_at: @now,
              merger_url: "https://example.test/42"
            }),
            worker("bd-b", :awaiting_review, %{mr_ref: "!41", step_started_at: @yesterday})
          ]
        )

      assert ids(board.merge_queue) == ["bd-b", "bd-a"]
      assert [_, %{mr_ref: "!42", merger_url: "https://example.test/42"}] = board.merge_queue
    end
  end

  describe "closed today column" do
    test "keeps only issues closed on the board's current day, newest first" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, updated_at: ~U[2026-08-22 09:00:00Z]}),
            issue("bd-b", %{status: :closed, updated_at: ~U[2026-08-22 11:00:00Z]}),
            issue("bd-c", %{status: :closed, updated_at: @yesterday})
          ]
        )

      assert ids(board.closed_today) == ["bd-b", "bd-a"]
    end
  end

  describe "board-wide holds" do
    test "an exhausted quota blocks promotion and names itself" do
      board = derive(issues: [issue("bd-a")], quota: {:hold, "quota exhausted"})

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — quota exhausted"}] = board.ready
    end

    test "a paused board dispatches nothing" do
      board = derive(issues: [issue("bd-a")], paused: true)

      assert board.promote == nil
      assert [%{state: :blocked, reason: "scheduler paused"}] = board.ready
    end
  end
end
