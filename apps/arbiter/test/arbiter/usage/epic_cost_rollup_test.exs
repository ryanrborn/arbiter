defmodule Arbiter.Usage.EpicCostRollupTest do
  @moduledoc """
  bd-8h5iyc — "$X spent · ~$Y-Z to go" epic cost rollup (design bd-9jj5lf §4):
  closed children contribute actual spend; open, promoted children all
  contribute a defensible "to go" figure regardless of whether they're
  dispatchable, blocked, in flight, or themselves sub-epics — being blocked
  or mid-flight doesn't change a task's cost basis, only when it runs.
  Unpromoted Backlog children are reported separately as "upcoming".
  """

  # async: false — the estimator reads the whole ledger, so a concurrent test
  # writing usage rows would leak into this one's sample.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "ecr-ws-#{n}", prefix: "ecr#{n}"})
    {:ok, epic} = Ash.create(Issue, %{title: "an epic", workspace_id: ws.id, issue_type: :epic})

    %{ws: ws, epic: epic}
  end

  # ---- fixtures ------------------------------------------------------------

  defp event!(task_id, cost) do
    {:ok, ev} =
      Ash.create(Event, %{
        task_id: task_id,
        source: :task,
        step: :work,
        workspace_id: "ecr-ws",
        occurred_at: @now,
        base_task_id: task_id,
        role: "base",
        cost_usd: cost
      })

    ev
  end

  defp attach!(epic, child), do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

  defp closed_child!(ws, epic, cost, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "closed child", workspace_id: ws.id}, attrs))

    event!(issue.id, cost)
    closed = Ash.update!(issue, %{close_upstream: false}, action: :close)
    attach!(epic, closed)
    closed
  end

  defp ready_child!(ws, epic, attrs) do
    {waived, attrs} = Map.pop(attrs, :acceptance_waived)

    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "ready child", workspace_id: ws.id, difficulty: 2}, attrs)
      )

    promote_params = if waived, do: %{acceptance_waived: waived}, else: %{}
    ready = Ash.update!(issue, promote_params, action: :promote_to_ready)
    attach!(epic, ready)
    ready
  end

  defp backlog_child!(ws, epic, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "backlog child", workspace_id: ws.id}, attrs))

    attach!(epic, issue)
    issue
  end

  defp running_child!(ws, epic) do
    child = ready_child!(ws, epic, %{issue_type: :task})
    Ash.update!(child, %{status: :in_progress})
  end

  defp waiting_child!(ws, epic) do
    child = running_child!(ws, epic)
    Ash.update!(child, %{}, action: :await_verification)
  end

  # A large, evenly-spread D2/task sample so `for_issue/2` clears the n>=10
  # floor and returns a stable, known p25/p75 for the "to go" math.
  defp seed_estimator_sample!(ws) do
    Enum.each(1..12, fn i ->
      {:ok, issue} =
        Ash.create(Issue, %{
          title: "sample #{i}",
          workspace_id: ws.id,
          difficulty: 2,
          issue_type: :task
        })

      event!(issue.id, i * 1.0)
      Ash.update!(issue, %{close_upstream: false}, action: :close)
    end)
  end

  describe "epic_cost_rollup/2" do
    test "closed children contribute their actual spend", ctx do
      closed_child!(ctx.ws, ctx.epic, 12.5)
      closed_child!(ctx.ws, ctx.epic, 7.5)

      rollup = Estimate.epic_cost_rollup(ctx.epic)

      assert rollup.spent == 20.0
      assert rollup.closed_count == 2
    end

    test "open, promoted, dispatchable children contribute summed p25-p75 estimates", ctx do
      seed_estimator_sample!(ctx.ws)
      ready_child!(ctx.ws, ctx.epic, %{difficulty: 2, issue_type: :task})
      ready_child!(ctx.ws, ctx.epic, %{difficulty: 2, issue_type: :task})

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)

      assert rollup.to_go_low == Float.round(est.p25 * 2, 2)
      assert rollup.to_go_high == Float.round(est.p75 * 2, 2)
      assert rollup.dispatchable_count == 2
    end

    test "blocked children contribute their full p25-p75 estimate, chained epic fixture", ctx do
      seed_estimator_sample!(ctx.ws)
      blocked = ready_child!(ctx.ws, ctx.epic, %{difficulty: 2, issue_type: :task})
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)

      assert rollup.to_go_low == Float.round(est.p25, 2)
      assert rollup.to_go_high == Float.round(est.p75, 2)
      assert rollup.dispatchable_count == 0
      assert rollup.blocked_count == 1
    end

    test "running children contribute max(estimate - spend, 0) and count as in-flight", ctx do
      seed_estimator_sample!(ctx.ws)
      running = running_child!(ctx.ws, ctx.epic)
      event!(running.id, 1.0)

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)

      assert rollup.to_go_low == Float.round(max(est.p25 - 1.0, 0.0), 2)
      assert rollup.to_go_high == Float.round(max(est.p75 - 1.0, 0.0), 2)
      assert rollup.dispatchable_count == 0
      assert rollup.in_flight_count == 1
    end

    test "waiting children contribute max(estimate - spend, 0) and count as in-flight", ctx do
      seed_estimator_sample!(ctx.ws)
      waiting_child!(ctx.ws, ctx.epic)

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)

      assert rollup.to_go_low == Float.round(est.p25, 2)
      assert rollup.to_go_high == Float.round(est.p75, 2)
      assert rollup.in_flight_count == 1
    end

    test "in-flight spend over the estimate floors the contribution at 0", ctx do
      seed_estimator_sample!(ctx.ws)
      running = running_child!(ctx.ws, ctx.epic)
      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)
      event!(running.id, est.p75 + 100.0)

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      assert rollup.to_go_low == 0.0
      assert rollup.to_go_high == 0.0
      assert rollup.in_flight_count == 1
    end

    test "sub-epic children contribute their own rollup's to-go recursively", ctx do
      seed_estimator_sample!(ctx.ws)

      {:ok, sub_epic} =
        Ash.create(Issue, %{title: "sub-epic", workspace_id: ctx.ws.id, issue_type: :epic})

      sub_epic = Ash.update!(sub_epic, %{}, action: :promote_to_ready)
      attach!(ctx.epic, sub_epic)

      ready_child!(ctx.ws, sub_epic, %{difficulty: 2, issue_type: :task})
      ready_child!(ctx.ws, sub_epic, %{difficulty: 2, issue_type: :task})

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)
      sub_rollup = Estimate.epic_cost_rollup(sub_epic, now: @now)

      assert rollup.to_go_low == sub_rollup.to_go_low
      assert rollup.to_go_high == sub_rollup.to_go_high
      assert rollup.sub_epic_count == 1
      assert rollup.dispatchable_count == 0
    end

    test "a cycle between epics does not loop forever and contributes nothing extra", ctx do
      seed_estimator_sample!(ctx.ws)
      epic = Ash.update!(ctx.epic, %{}, action: :promote_to_ready)

      {:ok, other_epic} =
        Ash.create(Issue, %{title: "cyclic epic", workspace_id: ctx.ws.id, issue_type: :epic})

      other_epic = Ash.update!(other_epic, %{}, action: :promote_to_ready)
      attach!(epic, other_epic)
      attach!(other_epic, epic)
      ready_child!(ctx.ws, other_epic, %{difficulty: 2, issue_type: :task})

      rollup = Estimate.epic_cost_rollup(epic, now: @now)
      est = Estimate.for_issue(%Issue{difficulty: 2, issue_type: :task}, now: @now)

      # counted exactly once — the back-edge to `epic` is skipped, not re-walked
      assert rollup.to_go_low == Float.round(est.p25, 2)
      assert rollup.to_go_high == Float.round(est.p75, 2)
      assert rollup.sub_epic_count == 1
    end

    test "unpromoted Backlog children are shown separately as upcoming", ctx do
      backlog_child!(ctx.ws, ctx.epic)
      backlog_child!(ctx.ws, ctx.epic)

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      assert rollup.upcoming_count == 2
      assert rollup.to_go_low == 0.0
      assert rollup.to_go_high == 0.0
      assert rollup.dispatchable_count == 0
    end

    test "a childless epic rolls up to all zeroes", ctx do
      rollup = Estimate.epic_cost_rollup(ctx.epic)

      assert rollup.spent == 0.0
      assert rollup.to_go_low == 0.0
      assert rollup.to_go_high == 0.0
      assert rollup.closed_count == 0
      assert rollup.dispatchable_count == 0
      assert rollup.blocked_count == 0
      assert rollup.in_flight_count == 0
      assert rollup.sub_epic_count == 0
      assert rollup.upcoming_count == 0
    end

    test "non-epic issues have no cost rollup", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "not an epic", workspace_id: ctx.ws.id})
      assert Estimate.epic_cost_rollup(task) == nil
    end

    test "a dispatchable child with insufficient estimator data is counted but not summed", ctx do
      ready_child!(ctx.ws, ctx.epic, %{
        difficulty: 4,
        issue_type: :chore,
        acceptance_waived: "test fixture"
      })

      rollup = Estimate.epic_cost_rollup(ctx.epic, now: @now)

      assert rollup.to_go_low == 0.0
      assert rollup.to_go_high == 0.0
      assert rollup.dispatchable_count == 1
      assert rollup.unestimated_count == 1
    end

    test "the whole ledger is still read exactly once per rollup, across every child category",
         ctx do
      seed_estimator_sample!(ctx.ws)
      ready_child!(ctx.ws, ctx.epic, %{difficulty: 2, issue_type: :task})
      running_child!(ctx.ws, ctx.epic)
      waiting_child!(ctx.ws, ctx.epic)

      blocked = ready_child!(ctx.ws, ctx.epic, %{difficulty: 2, issue_type: :task})
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      {:ok, sub_epic} =
        Ash.create(Issue, %{title: "sub-epic", workspace_id: ctx.ws.id, issue_type: :epic})

      sub_epic = Ash.update!(sub_epic, %{}, action: :promote_to_ready)
      attach!(ctx.epic, sub_epic)
      ready_child!(ctx.ws, sub_epic, %{difficulty: 2, issue_type: :task})

      :meck.new(Estimate, [:passthrough])

      try do
        Estimate.epic_cost_rollup(ctx.epic, now: @now)
        assert :meck.num_calls(Estimate, :sample, :_) == 1
      after
        :meck.unload(Estimate)
      end
    end
  end
end
