defmodule Arbiter.Tasks.EpicRollupTest do
  @moduledoc """
  bd-2wmxt5 — the per-status child aggregation behind `/epics`.

  bd-58z2tu replaced the three independent "stuck" signals with a single
  `needs_you` rule: an epic needs the operator when a child is parked in
  `awaiting_verification` (rule 1), a child's own live worker needs the
  operator per the board's shared `Snapshot.child_needs_you?/2` (rule 2), or
  a child is blocked only by something that itself needs the operator
  (rule 3). `blocked_children` / `idle_with_ready_work` stay as
  informational counts.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.EpicRollup
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

  defp worker(task_id, status, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: task_id,
        status: status,
        meta: %{}
      },
      attrs
    )
  end

  defp rollup(epic, opts \\ []), do: Map.fetch!(EpicRollup.for_epics([epic], opts), epic.id)

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
      refute r.needs_you
      assert r.needs_you_reasons == []
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

  describe "blocked_children and idle_with_ready_work (informational only)" do
    test "a child blocked by an open gating edge counts, but does not alone flag needs_you",
         ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "the blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.blocked_children == 1
      refute r.needs_you
    end

    test "a closed blocker no longer counts as blocking", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)
      Ash.update!(blocker, %{}, action: :close)

      r = rollup(ctx.epic)

      assert r.blocked_children == 0
    end

    test "an inbound :blocks edge blocks the child too", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "the blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocker.id, blocked.id, :blocks)

      assert rollup(ctx.epic).blocked_children == 1
    end

    test "zero running children with a Ready child counts as idle, but does not flag needs_you",
         ctx do
      child(ctx.ws, ctx.epic, "r1", as: :ready)

      r = rollup(ctx.epic)

      assert r.idle_with_ready_work
      refute r.needs_you
    end

    test "no Ready children means no idle signal, however quiet the epic is", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)

      r = rollup(ctx.epic)

      refute r.idle_with_ready_work
      refute r.needs_you
    end
  end

  describe "needs_you rule 1: a child awaiting verification" do
    test "flags needs_you with a verify reason naming the child", ctx do
      w1 = child(ctx.ws, ctx.epic, "w1", as: :waiting)
      child(ctx.ws, ctx.epic, "r1", as: :ready)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert r.awaiting_verification == 1
      assert "verify #{w1.id}" in r.needs_you_reasons
    end
  end

  describe "needs_you rule 2: a child's own worker needs the operator" do
    test "a live :awaiting worker (a question) flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "asking-child", as: :running)
      w = worker(c.id, :awaiting, %{meta: %{await_reason: "which?"}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "a live :failed worker (parked) flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "failed-child", as: :running)
      w = worker(c.id, :failed, %{meta: %{stop_reason: %{summary: "review rejected"}}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an in_progress child with no live worker at all flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "orphaned-child", as: :running)

      r = rollup(ctx.epic, workers: [])

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an approved MR blocked on something the Watchdog can't clear flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "blocked-mr-child", as: :running)

      w =
        worker(c.id, :awaiting_review, %{
          meta: %{last_merger_status: %{approved: true, block_reason: :needs_approval}}
        })

      r = rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([c.id]))

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an approved MR blocked on an auto-resolvable reason does not flag needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "auto-resolvable-child", as: :running)

      w =
        worker(c.id, :awaiting_review, %{
          meta: %{last_merger_status: %{approved: true, block_reason: :ci_failed}}
        })

      r = rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([c.id]))

      refute r.needs_you
    end

    test "a running child with a live author worker does not flag needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "running-child", as: :running)
      w = worker(c.id, :running)

      r = rollup(ctx.epic, workers: [w])

      refute r.needs_you
    end

    test "an in-review child mid-review (no merger status yet) does not flag needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "reviewing-child", as: :running)
      w = worker(c.id, :awaiting_review, %{meta: %{}})

      r = rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([c.id]))

      refute r.needs_you
    end

    test "agrees with the board's own needs_you flag for the same worker fixture", ctx do
      c = child(ctx.ws, ctx.epic, "shared-predicate-child", as: :running)

      w =
        worker(c.id, :awaiting_review, %{
          mr_ref: "!7",
          meta: %{last_merger_status: %{approved: true, block_reason: :needs_approval}}
        })

      watchdog_live = MapSet.new([c.id])

      epic_r = rollup(ctx.epic, workers: [w], watchdog_live: watchdog_live)

      board =
        Snapshot.derive(%{
          issues: [c],
          workers: [w],
          blocked_by: %{},
          changed_files: %{},
          now: DateTime.utc_now(),
          slots_total: 4,
          quota: :ok,
          paused: false,
          watchdog_live: watchdog_live
        })

      [card] = board.waiting

      assert card.needs_you == true
      assert epic_r.needs_you == card.needs_you
    end
  end

  describe "needs_you rule 3: blocked only by something that itself needs the operator" do
    test "blocked by an unrefined (Backlog) blocker flags needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "unrefined blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert "blocked by unrefined #{blocker.id}" in r.needs_you_reasons
    end

    test "blocked by an awaiting_verification blocker flags needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "waiting blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{}, action: :await_verification)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert "blocked by #{blocker.id} (awaiting verification)" in r.needs_you_reasons
    end

    test "blocked by a parked (needs-you) blocker flags needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "parked blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :failed, %{meta: %{stop_reason: %{summary: "gave up"}}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "blocked by #{blocker.id} (parked)" in r.needs_you_reasons
    end

    test "a blocker outside the epic still counts", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, other_epic} =
        Ash.create(Issue, %{title: "other epic", workspace_id: ctx.ws.id, issue_type: :epic})

      outside_blocker = child(ctx.ws, other_epic, "outside-blocker", as: :backlog)
      {:ok, _} = Dependencies.add(blocked.id, outside_blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert "blocked by unrefined #{outside_blocker.id}" in r.needs_you_reasons
    end

    test "blocked by a Ready blocker does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "ready blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      refute rollup(ctx.epic).needs_you
    end

    test "blocked by a running blocker with a live worker does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "running blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :running)

      refute rollup(ctx.epic, workers: [w]).needs_you
    end

    test "blocked by a blocker mid-review with a live watchdog does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "reviewing blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :awaiting_review, %{meta: %{}})

      refute rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([blocker.id])).needs_you
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
