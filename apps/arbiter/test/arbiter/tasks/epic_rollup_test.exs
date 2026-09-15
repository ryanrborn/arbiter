defmodule Arbiter.Tasks.EpicRollupTest do
  @moduledoc """
  bd-2wmxt5 — the per-status child aggregation behind `/epics`: how many
  children an epic has in each board bucket, and the three derived stuck
  signals (blocked children / awaiting verification / idle with ready work).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])

    {:ok, ws} = Ash.create(Workspace, %{name: "epic-ws-#{n}", prefix: "epr#{n}"})

    {:ok, epic} =
      Ash.create(Issue, %{title: "an epic", workspace_id: ws.id, issue_type: :epic})

    {:ok, ws: ws, epic: epic}
  end

  defp child(ws, epic, title, opts) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, issue_type: :task})

    issue =
      case Keyword.get(opts, :as) do
        :backlog -> issue
        :ready -> Ash.update!(issue, %{}, action: :promote_to_ready)
        :running -> Ash.update!(issue, %{status: :in_progress})
        :waiting -> Ash.update!(issue, %{}, action: :await_verification)
        :closed -> Ash.update!(issue, %{}, action: :close)
      end

    {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)
    issue
  end

  defp rollup(epic), do: Map.fetch!(Tasks.epic_rollups([epic]), epic.id)

  describe "per-status child counts" do
    test "buckets children into backlog/ready/running/waiting/closed", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      child(ctx.ws, ctx.epic, "b2", as: :backlog)
      child(ctx.ws, ctx.epic, "r1", as: :ready)
      child(ctx.ws, ctx.epic, "run1", as: :running)
      child(ctx.ws, ctx.epic, "w1", as: :waiting)
      child(ctx.ws, ctx.epic, "c1", as: :closed)
      child(ctx.ws, ctx.epic, "c2", as: :closed)

      r = rollup(ctx.epic)

      assert r.counts == %{backlog: 2, ready: 1, running: 1, waiting: 1, closed: 2}
      assert r.total == 7
      assert r.closed == 2
    end

    test "an epic with no children rolls up to all zeroes", ctx do
      r = rollup(ctx.epic)

      assert r.counts == %{backlog: 0, ready: 0, running: 0, waiting: 0, closed: 0}
      assert r.total == 0
      assert r.closed == 0
      assert r.percent_complete == 0
      assert r.stuck == []
    end

    test "percent_complete is closed over total", ctx do
      child(ctx.ws, ctx.epic, "c1", as: :closed)
      child(ctx.ws, ctx.epic, "c2", as: :closed)
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      child(ctx.ws, ctx.epic, "b2", as: :backlog)

      assert rollup(ctx.epic).percent_complete == 50
    end

    test "only :parent_of children count, not other edge types", ctx do
      {:ok, related} = Ash.create(Issue, %{title: "related", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(ctx.epic.id, related.id, :relates_to)

      assert rollup(ctx.epic).total == 0
    end
  end

  describe "stuck signals" do
    test "a child blocked by an open gating edge flags :blocked_children", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.blocked_children == 1
      assert :blocked_children in r.stuck
    end

    test "a closed blocker no longer counts as blocking", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)
      Ash.update!(blocker, %{}, action: :close)

      r = rollup(ctx.epic)

      assert r.blocked_children == 0
      refute :blocked_children in r.stuck
    end

    test "an inbound :blocks edge blocks the child too", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocker.id, blocked.id, :blocks)

      assert rollup(ctx.epic).blocked_children == 1
    end

    test "a child awaiting verification flags :awaiting_verification", ctx do
      child(ctx.ws, ctx.epic, "w1", as: :waiting)
      child(ctx.ws, ctx.epic, "run1", as: :running)

      r = rollup(ctx.epic)

      assert r.awaiting_verification == 1
      assert :awaiting_verification in r.stuck
    end

    test "zero running children with a Ready child flags :idle_with_ready_work", ctx do
      child(ctx.ws, ctx.epic, "r1", as: :ready)

      r = rollup(ctx.epic)

      assert r.idle_with_ready_work
      assert :idle_with_ready_work in r.stuck
    end

    test "a running child clears :idle_with_ready_work even with Ready work left", ctx do
      child(ctx.ws, ctx.epic, "r1", as: :ready)
      child(ctx.ws, ctx.epic, "run1", as: :running)

      r = rollup(ctx.epic)

      refute r.idle_with_ready_work
      refute :idle_with_ready_work in r.stuck
    end

    test "no Ready children means no idle signal, however quiet the epic is", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)

      r = rollup(ctx.epic)

      refute r.idle_with_ready_work
      assert r.stuck == []
    end
  end

  describe "last_child_activity_at" do
    test "is the newest child updated_at", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      newest = child(ctx.ws, ctx.epic, "b2", as: :closed)

      r = rollup(ctx.epic)

      assert r.last_child_activity_at
      assert DateTime.compare(r.last_child_activity_at, newest.updated_at) != :lt
    end

    test "is nil for a childless epic", ctx do
      assert rollup(ctx.epic).last_child_activity_at == nil
    end
  end

  describe "open_epic_count/0" do
    test "counts non-closed epics only", ctx do
      {:ok, second} =
        Ash.create(Issue, %{title: "second epic", workspace_id: ctx.ws.id, issue_type: :epic})

      {:ok, third} =
        Ash.create(Issue, %{title: "third epic", workspace_id: ctx.ws.id, issue_type: :epic})

      {:ok, _plain} = Ash.create(Issue, %{title: "not an epic", workspace_id: ctx.ws.id})

      before = Tasks.open_epic_count()
      Ash.update!(third, %{}, action: :close)

      assert Tasks.open_epic_count() == before - 1
      assert second.status == :open
    end
  end

  test "rolls up several epics in one call", ctx do
    {:ok, other} =
      Ash.create(Issue, %{title: "other epic", workspace_id: ctx.ws.id, issue_type: :epic})

    child(ctx.ws, ctx.epic, "a1", as: :closed)
    child(ctx.ws, other, "b1", as: :ready)

    rollups = Tasks.epic_rollups([ctx.epic, other])

    assert rollups[ctx.epic.id].counts.closed == 1
    assert rollups[other.id].counts.ready == 1
  end
end
