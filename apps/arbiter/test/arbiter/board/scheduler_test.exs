defmodule Arbiter.Board.SchedulerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Scheduler

  defp card(id, opts \\ []) do
    %{
      id: id,
      scope: MapSet.new(Keyword.get(opts, :files, [])),
      blocked_by: Keyword.get(opts, :blocked_by, [])
    }
  end

  defp running(task_id, files) do
    %{task_id: task_id, scope: MapSet.new(files)}
  end

  defp plan(overrides) do
    Scheduler.plan(
      Map.merge(
        %{ready: [], running: [], slots_free: 1, quota: :ok, paused: false},
        Map.new(overrides)
      )
    )
  end

  defp reason(plan, id) do
    Enum.find(plan.entries, &(&1.id == id))
  end

  describe "promotion" do
    test "promotes the top ready card when a slot is free" do
      plan = plan(ready: [card("bd-1"), card("bd-2")])

      assert plan.promote == "bd-1"
      assert %{state: :next, reason: "next up — dispatching..."} = reason(plan, "bd-1")
    end

    test "promotes at most one card per plan, whatever the headroom" do
      plan = plan(ready: [card("bd-1"), card("bd-2"), card("bd-3")], slots_free: 3)

      assert plan.promote == "bd-1"
      assert %{state: :queued, reason: "1 ahead in queue"} = reason(plan, "bd-2")
      assert %{state: :queued, reason: "2 ahead in queue"} = reason(plan, "bd-3")
    end

    test "an empty ready queue promotes nothing" do
      assert %{promote: nil, entries: []} = plan(ready: [])
    end
  end

  describe "concurrency" do
    test "no free slot holds the top card and names the reason" do
      plan = plan(ready: [card("bd-1"), card("bd-2")], slots_free: 0)

      assert plan.promote == nil
      assert %{state: :blocked, reason: "blocked — no free worker slot"} = reason(plan, "bd-1")
      assert %{state: :queued, reason: "1 ahead in queue"} = reason(plan, "bd-2")
    end
  end

  describe "dependencies" do
    test "a card with an open blocker is blocked and skipped over" do
      plan = plan(ready: [card("bd-1", blocked_by: ["bd-9"]), card("bd-2")])

      assert plan.promote == "bd-2"
      assert %{state: :blocked, reason: "blocked — waiting on bd-9"} = reason(plan, "bd-1")
      assert %{state: :next} = reason(plan, "bd-2")
    end

    test "several blockers are listed" do
      plan = plan(ready: [card("bd-1", blocked_by: ["bd-9", "bd-8"])])

      assert %{reason: "blocked — waiting on bd-8, bd-9"} = reason(plan, "bd-1")
    end
  end

  describe "file overlap" do
    test "a card whose files are in flight is blocked and skipped over" do
      plan =
        plan(
          ready: [card("bd-1", files: ["lib/a.ex"]), card("bd-2", files: ["lib/b.ex"])],
          running: [running("bd-7", ["lib/a.ex"])]
        )

      assert plan.promote == "bd-2"

      assert %{state: :blocked, reason: "blocked — lib/a.ex in flight on bd-7"} =
               reason(plan, "bd-1")
    end

    test "several colliding files collapse to the first plus a count" do
      plan =
        plan(
          ready: [card("bd-1", files: ["lib/a.ex", "lib/b.ex", "lib/c.ex"])],
          running: [running("bd-7", ["lib/a.ex", "lib/b.ex", "lib/c.ex"])]
        )

      assert %{reason: "blocked — lib/a.ex +2 more in flight on bd-7"} = reason(plan, "bd-1")
    end

    test "the card promoted this cycle is itself treated as in flight" do
      plan =
        plan(
          ready: [card("bd-1", files: ["lib/a.ex"]), card("bd-2", files: ["lib/a.ex"])],
          slots_free: 2
        )

      assert plan.promote == "bd-1"

      assert %{state: :blocked, reason: "blocked — lib/a.ex in flight on bd-1"} =
               reason(plan, "bd-2")
    end

    test "a card held by a global block does not claim its files" do
      plan =
        plan(
          ready: [card("bd-1", files: ["lib/a.ex"]), card("bd-2", files: ["lib/a.ex"])],
          slots_free: 0
        )

      assert %{state: :blocked, reason: "blocked — no free worker slot"} = reason(plan, "bd-1")
      assert %{state: :queued, reason: "1 ahead in queue"} = reason(plan, "bd-2")
    end
  end

  describe "quota" do
    test "an exhausted quota holds promotion and surfaces as a blocked reason" do
      plan = plan(ready: [card("bd-1")], quota: {:hold, "quota exhausted"})

      assert plan.promote == nil
      assert %{state: :blocked, reason: "blocked — quota exhausted"} = reason(plan, "bd-1")
    end

    test "quota outranks a missing slot when both would hold" do
      plan = plan(ready: [card("bd-1")], quota: {:hold, "quota near exhaustion"}, slots_free: 0)

      assert %{reason: "blocked — quota near exhaustion"} = reason(plan, "bd-1")
    end
  end

  describe "pause" do
    test "a paused scheduler promotes nothing and says so on every card" do
      plan = plan(ready: [card("bd-1"), card("bd-2")], paused: true)

      assert plan.promote == nil

      assert Enum.all?(plan.entries, &match?(%{state: :blocked, reason: "scheduler paused"}, &1))
    end

    test "pause still reports a real block ahead of itself" do
      plan = plan(ready: [card("bd-1", blocked_by: ["bd-9"])], paused: true)

      assert %{reason: "blocked — waiting on bd-9"} = reason(plan, "bd-1")
    end
  end

  describe "entries" do
    test "preserve queue order" do
      plan = plan(ready: [card("bd-3"), card("bd-1"), card("bd-2")])

      assert Enum.map(plan.entries, & &1.id) == ["bd-3", "bd-1", "bd-2"]
    end
  end
end
