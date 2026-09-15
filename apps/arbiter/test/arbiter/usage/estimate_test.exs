defmodule Arbiter.Usage.EstimateTest do
  @moduledoc """
  Unit tests for the cost estimator (bd-3j4ch4, design bd-9jj5lf §1/§2/§6).

  Every fixture below writes real `usage_events` + `issues` rows, because the
  data-hygiene rules under test (synthetic-id folding, unpriced rows, the
  60-day window) are properties of the *query*, not of a pure function.
  """

  # async: false — the estimator reads the whole ledger, so a concurrent
  # test writing usage rows would leak into this one's sample.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "est-ws-#{System.unique_integer([:positive])}",
        prefix: "ew"
      })

    %{ws: ws}
  end

  # ---- fixtures ----------------------------------------------------------

  defp open_issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "estimate subject", workspace_id: ws.id}, attrs)
      )

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
      workspace_id: "ws-est",
      occurred_at: @now,
      base_task_id: task_id,
      role: "base"
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  # n closed tasks at (difficulty, issue_type), one priced :work row each.
  defp tasks_with_costs!(ws, difficulty, issue_type, costs, event_attrs \\ %{}) do
    Enum.map(costs, fn cost ->
      issue = closed_issue!(ws, %{difficulty: difficulty, issue_type: issue_type})
      event!(issue.id, Map.merge(%{cost_usd: cost}, event_attrs))
      issue
    end)
  end

  # ---- AC1: the fallback ladder ------------------------------------------

  describe "for_issue/1 fallback ladder" do
    test "rung 1: uses (difficulty, issue_type) when that group has n >= 10", %{ws: ws} do
      tasks_with_costs!(ws, 2, :feature, Enum.map(1..10, &(&1 * 1.0)))
      # A same-difficulty, different-type group that must NOT bleed into the
      # answer — its costs are two orders of magnitude apart.
      tasks_with_costs!(ws, 2, :bug, Enum.map(1..10, &(&1 * 100.0)))

      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})

      est = Estimate.for_issue(subject, now: @now)

      assert est.basis == "difficulty+type"
      assert est.fallback_level == 0
      assert est.n == 10
      assert est.p25 == 3.0
      assert est.median == 5.0
      assert est.p75 == 8.0
      assert est.p90 == 9.0
    end

    test "rung 2: falls back to difficulty-only when the typed group is thin", %{ws: ws} do
      # 4 D3 features + 8 D3 chores = 12 at D3, but only 4 at (D3, feature).
      tasks_with_costs!(ws, 3, :feature, [1.0, 2.0, 3.0, 4.0])
      tasks_with_costs!(ws, 3, :chore, Enum.map(5..12, &(&1 * 1.0)))

      subject = open_issue!(ws, %{difficulty: 3, issue_type: :feature})

      est = Estimate.for_issue(subject, now: @now)

      assert est.basis == "difficulty"
      assert est.fallback_level == 1
      assert est.n == 12
      # costs 1..12: nearest-rank p25 = 3rd, median = 6th, p75 = 9th, p90 = 11th
      assert est.p25 == 3.0
      assert est.median == 6.0
      assert est.p75 == 9.0
      assert est.p90 == 11.0
    end

    test "rung 3: falls back to the global sample when the difficulty is thin", %{ws: ws} do
      tasks_with_costs!(ws, 3, :chore, Enum.map(1..12, &(&1 * 1.0)))

      # D5 has no history at all.
      subject = open_issue!(ws, %{difficulty: 5, issue_type: :feature})

      est = Estimate.for_issue(subject, now: @now)

      assert est.basis == "global"
      assert est.fallback_level == 2
      assert est.n == 12
      assert est.median == 6.0
    end

    test "returns :insufficient_data when even the global sample is under n = 10", %{ws: ws} do
      tasks_with_costs!(ws, 2, :feature, [1.0, 2.0, 3.0, 4.0, 5.0])

      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})

      assert Estimate.for_issue(subject, now: @now) == :insufficient_data
    end

    test "accepts a task id as well as a loaded issue", %{ws: ws} do
      tasks_with_costs!(ws, 2, :feature, Enum.map(1..10, &(&1 * 1.0)))
      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})

      assert Estimate.for_issue(subject.id, now: @now) ==
               Estimate.for_issue(subject, now: @now)
    end
  end

  # ---- AC2: data hygiene -------------------------------------------------

  describe "data hygiene" do
    test "folds review / impl spend onto the base task via base_task_id", %{ws: ws} do
      issue = closed_issue!(ws, %{difficulty: 2})

      event!(issue.id, %{cost_usd: 2.0})

      event!(issue.id <> "#review", %{
        cost_usd: 1.0,
        step: :review,
        base_task_id: issue.id,
        role: "review"
      })

      event!(issue.id <> "#impl1", %{
        cost_usd: 0.5,
        step: :impl,
        base_task_id: issue.id,
        role: "impl"
      })

      assert [row] = Estimate.sample(now: @now)
      assert row.task_id == issue.id
      assert_in_delta row.cost_usd, 3.5, 1.0e-9
    end

    test "folds pre-migration synthetic task_id suffixes with no base_task_id", %{ws: ws} do
      issue = closed_issue!(ws, %{difficulty: 2})

      # Rows written before migration 20260820000000 (bd-5fhyry) carry no
      # base_task_id at all — only the suffix on task_id.
      for {suffix, cost} <- [
            {"", 2.0},
            {"#review", 1.0},
            {"#r2", 0.5},
            {"#impl2", 0.25},
            {"#v2", 0.125},
            {":fixpass", 0.0625}
          ] do
        event!(issue.id <> suffix, %{cost_usd: cost, base_task_id: nil, role: nil})
      end

      assert [row] = Estimate.sample(now: @now)
      assert row.task_id == issue.id
      assert_in_delta row.cost_usd, 3.9375, 1.0e-9
    end

    test "excludes null-cost rows rather than counting them as $0", %{ws: ws} do
      issue = closed_issue!(ws, %{difficulty: 2})

      event!(issue.id, %{cost_usd: 5.0})

      event!(issue.id <> "#review", %{
        cost_usd: nil,
        cost_note: "no priced model resolved",
        base_task_id: issue.id
      })

      assert [row] = Estimate.sample(now: @now)
      assert_in_delta row.cost_usd, 5.0, 1.0e-9
      assert row.unpriced_rows == 1
      assert row.priced_rows == 1
    end

    test "drops tasks whose every row is unpriced", %{ws: ws} do
      priced = closed_issue!(ws, %{difficulty: 2})
      event!(priced.id, %{cost_usd: 5.0})

      unpriced = closed_issue!(ws, %{difficulty: 2})
      event!(unpriced.id, %{cost_usd: nil, cost_note: "metered plan, no per-call cost"})

      assert [row] = Estimate.sample(now: @now)
      assert row.task_id == priced.id
    end

    test "counts only closed tasks", %{ws: ws} do
      closed = closed_issue!(ws, %{difficulty: 2})
      event!(closed.id, %{cost_usd: 5.0})

      still_open = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(still_open.id, %{cost_usd: 99.0})

      assert [row] = Estimate.sample(now: @now)
      assert row.task_id == closed.id
    end

    test "counts only worker spend (source = :task)", %{ws: ws} do
      issue = closed_issue!(ws, %{difficulty: 2})
      event!(issue.id, %{cost_usd: 5.0})
      event!(issue.id, %{cost_usd: 40.0, source: :preflight})

      assert [row] = Estimate.sample(now: @now)
      assert_in_delta row.cost_usd, 5.0, 1.0e-9
    end
  end

  # ---- AC3: window + recency weighting + unrated ------------------------

  describe "60-day window and recency weighting" do
    test "excludes spend older than the 60-day window", %{ws: ws} do
      recent = closed_issue!(ws, %{difficulty: 2})
      event!(recent.id, %{cost_usd: 5.0})

      stale = closed_issue!(ws, %{difficulty: 2})
      event!(stale.id, %{cost_usd: 99.0, occurred_at: DateTime.add(@now, -90, :day)})

      assert [row] = Estimate.sample(now: @now)
      assert row.task_id == recent.id
    end

    test "recency weighting pulls the percentiles toward recent spend", %{ws: ws} do
      # Five cheap tasks 55 days ago, five expensive ones today. An unweighted
      # median over these ten values is $1.00 (the 5th of 1,1,1,1,1,10,...).
      tasks_with_costs!(ws, 2, :feature, List.duplicate(1.0, 5), %{
        occurred_at: DateTime.add(@now, -55, :day)
      })

      tasks_with_costs!(ws, 2, :feature, List.duplicate(10.0, 5))

      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      est = Estimate.for_issue(subject, now: @now)

      assert est.n == 10
      assert est.median == 10.0
    end

    test "unrated issues borrow the D2 estimate, flagged", %{ws: ws} do
      tasks_with_costs!(ws, 2, :feature, Enum.map(1..10, &(&1 * 1.0)))

      rated = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      unrated = open_issue!(ws, %{difficulty: nil, issue_type: :feature})

      rated_est = Estimate.for_issue(rated, now: @now)
      unrated_est = Estimate.for_issue(unrated, now: @now)

      assert unrated_est.basis == "unrated_as_d2"
      assert unrated_est.fallback_level == rated_est.fallback_level
      assert unrated_est.n == rated_est.n
      assert unrated_est.median == rated_est.median
      assert unrated_est.p25 == rated_est.p25
      assert unrated_est.p75 == rated_est.p75
      assert unrated_est.p90 == rated_est.p90
    end
  end

  # ---- AC4: the calibration report --------------------------------------

  describe "calibration/1" do
    setup %{ws: ws} do
      tasks_with_costs!(ws, 1, :feature, Enum.map(1..10, &(&1 * 1.0)))
      tasks_with_costs!(ws, 2, :feature, Enum.map(11..20, &(&1 * 1.0)))
      tasks_with_costs!(ws, 3, :feature, Enum.map(21..30, &(&1 * 1.0)))

      # A D2 task that cost like a D3 one.
      [under] = tasks_with_costs!(ws, 2, :feature, [25.0])

      # A D2 task that cost like a D1 one.
      [over] = tasks_with_costs!(ws, 2, :feature, [5.0])

      # A D2 task that also looks under-rated, but only because it was
      # re-slung: two :work sessions. Process noise, not a mis-rating.
      reslung = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(reslung.id, %{cost_usd: 13.0})
      event!(reslung.id, %{cost_usd: 13.0})

      %{under: under, over: over, reslung: reslung}
    end

    test "flags a task whose actual cost fits the tier above", ctx do
      report = Estimate.calibration(now: @now)

      flag = Enum.find(report.flagged, &(&1.task_id == ctx.under.id))
      assert flag.direction == :under_rated
      assert flag.difficulty == 2
      assert flag.suggested_difficulty == 3
      assert_in_delta flag.actual_cost_usd, 25.0, 1.0e-9
      refute flag.re_dispatched
    end

    test "flags a task whose actual cost fits the tier below", ctx do
      report = Estimate.calibration(now: @now)

      flag = Enum.find(report.flagged, &(&1.task_id == ctx.over.id))
      assert flag.direction == :over_rated
      assert flag.suggested_difficulty == 1
      assert_in_delta flag.actual_cost_usd, 5.0, 1.0e-9
    end

    test "reports per-tier rates that exclude re-dispatched tasks", ctx do
      report = Estimate.calibration(now: @now)

      d2 = Enum.find(report.tiers, &(&1.difficulty == 2))
      assert d2.n == 13
      assert d2.re_dispatched == 1
      assert d2.n_scored == 12
      assert d2.under_rated == 1
      assert d2.over_rated == 1
      assert_in_delta d2.under_rate, 1 / 12, 1.0e-9
      assert_in_delta d2.over_rate, 1 / 12, 1.0e-9

      # The re-slung task is still listed, marked, so the operator can see it.
      reslung_flag = Enum.find(report.flagged, &(&1.task_id == ctx.reslung.id))
      assert reslung_flag.re_dispatched
      assert report.re_dispatched_flagged == 1
    end

    test "leaves tiers with no adjacent tier unflagged", _ctx do
      report = Estimate.calibration(now: @now)

      d1 = Enum.find(report.tiers, &(&1.difficulty == 1))
      d3 = Enum.find(report.tiers, &(&1.difficulty == 3))

      assert d1.under_rated == 0
      assert d1.over_rated == 0
      assert d3.under_rated == 0
      assert d3.over_rated == 0
      assert report.window_days == 60
    end
  end

  # ---- payload shape used by MCP / CLI ----------------------------------

  describe "payload/2" do
    test "renders the wire shape the MCP + CLI surfaces consume", %{ws: ws} do
      tasks_with_costs!(ws, 2, :feature, Enum.map(1..10, &(&1 * 1.0)))
      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})

      assert %{
               range: [3.0, 8.0],
               median: 5.0,
               p90: 9.0,
               n: 10,
               basis: "difficulty+type",
               fallback_level: 0
             } = Estimate.payload(subject, now: @now)
    end

    test "is nil when there is not enough data", %{ws: ws} do
      subject = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      assert Estimate.payload(subject, now: @now) == nil
    end
  end
end
