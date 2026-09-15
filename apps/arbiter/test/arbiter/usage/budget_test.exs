defmodule Arbiter.Usage.BudgetTest do
  @moduledoc """
  Worker spend so far vs. the estimate range, and the threshold states the
  issue header and the board read off it (bd-8j9i9p, design bd-9jj5lf §3/§7).
  """

  # async: false — the estimator behind `assess/2` reads the whole ledger, so a
  # concurrent test writing usage rows would leak into this one's sample.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Event

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "budget-ws-#{System.unique_integer([:positive])}",
        prefix: "bw"
      })

    %{ws: ws}
  end

  # ---- fixtures ----------------------------------------------------------

  defp open_issue!(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "budget subject", workspace_id: ws.id}, attrs))

    issue
  end

  defp closed_issue!(ws, attrs) do
    issue = open_issue!(ws, Map.merge(%{issue_type: :feature}, attrs))
    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  defp event!(task_id, attrs) do
    base = %{
      task_id: task_id,
      source: :task,
      step: :work,
      workspace_id: "ws-budget",
      occurred_at: @now,
      base_task_id: task_id,
      role: "base"
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  # A ledger with n=10 closed D2 features costing $1..$10, so the estimate is
  # a known ladder: p25 $3, median $5, p75 $8, p90 $9.
  defp seeded_history!(ws) do
    Enum.each(1..10, fn n ->
      issue = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(issue.id, %{cost_usd: n * 1.0})
    end)
  end

  # ---- AC1: spend so far -------------------------------------------------

  describe "spend_so_far/2" do
    test "sums priced worker rows for the task", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 1.25})
      event!(task.id, %{cost_usd: 2.50, step: :review})

      assert Budget.spend_so_far(task.id) == 3.75
    end

    test "folds review / fix-pass rows back onto the base task", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 1.0})

      event!(task.id <> "#review", %{
        cost_usd: 2.0,
        base_task_id: task.id,
        role: "reviewer",
        step: :review
      })

      # A pre-migration row: the synthetic suffix is the only link back.
      event!(task.id <> "#impl2", %{cost_usd: 4.0, base_task_id: nil, role: nil})

      assert Budget.spend_so_far(task.id) == 7.0
    end

    test "excludes unpriced rows rather than counting them as zero", %{ws: ws} do
      task = open_issue!(ws)
      event!(task.id, %{cost_usd: nil})

      assert Budget.spend_so_far(task.id) == 0.0
    end

    test "excludes spend that belongs to no task and to other sources", %{ws: ws} do
      task = open_issue!(ws)
      event!(task.id, %{cost_usd: 1.0})
      event!(task.id, %{cost_usd: 99.0, source: :coordinator_session})

      assert Budget.spend_so_far(task.id) == 1.0
    end

    test "a task with no ledger rows has spent nothing", %{ws: ws} do
      assert Budget.spend_so_far(open_issue!(ws).id) == 0.0
    end
  end

  describe "spend_by_task/2" do
    test "returns one total per task, and no key for a task with no spend", %{ws: ws} do
      a = open_issue!(ws)
      b = open_issue!(ws)
      c = open_issue!(ws)
      event!(a.id, %{cost_usd: 1.5})
      event!(b.id, %{cost_usd: 2.5})

      spends = Budget.spend_by_task([a.id, b.id, c.id])

      assert spends[a.id] == 1.5
      assert spends[b.id] == 2.5
      refute Map.has_key?(spends, c.id)
    end
  end

  # ---- AC2: the threshold states -----------------------------------------

  describe "state/2 thresholds" do
    setup %{ws: ws} do
      seeded_history!(ws)
      :ok
    end

    test "under p75 is plain — no chip", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 7.0})

      assert %{state: :normal, spend: 7.0, estimate: est} = Budget.assess(task, now: @now)
      assert est.p75 == 8.0
      assert est.p90 == 9.0
    end

    test "above p75 and at or under p90 is amber 'running high'", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 8.5})

      assert %{state: :running_high} = Budget.assess(task, now: @now)
    end

    test "exactly p75 is not yet running high", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 8.0})

      assert %{state: :normal} = Budget.assess(task, now: @now)
    end

    test "above p90 is red 'over budget'", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 12.0})

      assert %{state: :over_budget} = Budget.assess(task, now: @now)
    end

    test "exactly p90 is not yet over budget", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 9.0})

      assert %{state: :running_high} = Budget.assess(task, now: @now)
    end
  end

  describe "state/2 without an estimate" do
    test "too little history reads as 'no estimate yet', whatever the spend", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 500.0})

      assert %{state: :no_estimate, estimate: nil, spend: 500.0} = Budget.assess(task, now: @now)
    end
  end

  # ---- AC3: the board attention flag -------------------------------------

  describe "over_budget_ids/2" do
    setup %{ws: ws} do
      seeded_history!(ws)
      :ok
    end

    test "flags an open issue whose spend is past p90", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 30.0})

      assert task.id in Budget.over_budget_ids([task], now: @now)
    end

    test "never flags a closed issue, however far over it ran", %{ws: ws} do
      task = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 30.0})

      refute task.id in Budget.over_budget_ids([task], now: @now)
    end

    test "does not flag an open issue inside its range", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, %{cost_usd: 8.5})

      refute task.id in Budget.over_budget_ids([task], now: @now)
    end
  end
end
