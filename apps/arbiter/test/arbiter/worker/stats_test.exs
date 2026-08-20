defmodule Arbiter.Worker.StatsTest do
  use Arbiter.DataCase, async: true

  require Ash.Expr

  alias Arbiter.Usage.Event
  alias Arbiter.Worker.Stats

  defp create_event!(attrs) do
    base = %{
      repo: "arbiter",
      workspace_id: "ws-stats",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "task_costs_usd/1" do
    test "returns 0.0 for an empty task id list" do
      assert Stats.task_costs_usd([]) == %{}
    end

    test "sums a task's own :work rows" do
      task_id = "bd-stats-#{System.unique_integer([:positive])}"
      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.5, base_task_id: task_id, role: "base"})
      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.25, base_task_id: task_id, role: "base"})

      assert Stats.task_costs_usd([task_id]) == %{task_id => 0.75}
    end

    # bd-cryhwk: worker_list's cost_usd is documented as "sum of all ledger
    # entries for the task", but ReviewGate reviewer/implementer passes write
    # their Usage.Event rows under a synthetic, `#`-suffixed task id
    # (Worker.ReviewGate.reviewer_task_id/1, implementer_task_id/2) so the
    # spend is still attributable to the pass that earned it. task_costs_usd/1
    # filtered on exact task_id equality, so none of that suffixed spend was
    # ever rolled into the base task's total — the reported cost was strictly
    # less than a subset of the task's own review rounds.
    test "rolls up ReviewGate reviewer/implementer rows under the base task id" do
      task_id = "bd-stats-#{System.unique_integer([:positive])}"

      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.741102, base_task_id: task_id, role: "base"})
      create_event!(%{task_id: "#{task_id}#review", step: :review, cost_usd: 0.6449235, base_task_id: task_id, role: "review"})
      create_event!(%{task_id: "#{task_id}#review#impl1", step: :impl, cost_usd: 0.0833313, base_task_id: task_id, role: "impl"})
      create_event!(%{task_id: "#{task_id}#r2", step: :review, cost_usd: 0.4209582, base_task_id: task_id, role: "review"})

      assert %{^task_id => total} = Stats.task_costs_usd([task_id])
      assert_in_delta total, 1.890315, 0.000001
    end

    test "does not leak one task's rows into another task's total" do
      task_a = "bd-stats-a-#{System.unique_integer([:positive])}"
      task_b = "bd-stats-b-#{System.unique_integer([:positive])}"

      create_event!(%{task_id: task_a, step: :work, cost_usd: 1.0, base_task_id: task_a, role: "base"})
      create_event!(%{task_id: "#{task_b}#review", step: :review, cost_usd: 2.0, base_task_id: task_b, role: "review"})

      assert Stats.task_costs_usd([task_a]) == %{task_a => 1.0}
    end

    # bd-cryhwk (review round 1, finding 2): a ReviewGate reviewer/implementer
    # worker's own `Worker.list_children/0` snapshot carries the synthetic,
    # `#`-suffixed task id as its task_id (e.g. "<base>#review"). Callers that
    # don't pre-filter those out (worker_controller.index/2) look the cost up
    # by that exact suffixed id, so it must resolve to its own rows rather
    # than only ever being reachable through the base id's rollup.
    test "resolves an already-synthetic task id to its own rows, not the base rollup" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"
      review_id = "#{base_id}#review"

      create_event!(%{task_id: base_id, step: :work, cost_usd: 1.0, base_task_id: base_id, role: "base"})
      create_event!(%{task_id: review_id, step: :review, cost_usd: 2.0, base_task_id: base_id, role: "review"})

      assert Stats.task_costs_usd([review_id]) == %{review_id => 2.0}
    end

    # bd-cryhwk (review round 1, finding 1 & 2): every id passed in gets an
    # explicit key in the result, even one with zero recorded cost — so a
    # caller can distinguish "no cost recorded" from "absent", and a mixed
    # request of base ids and synthetic ids resolves each independently.
    test "returns an explicit key for every requested id, mixed base and synthetic" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"
      review_id = "#{base_id}#review"
      untouched_id = "bd-stats-untouched-#{System.unique_integer([:positive])}"

      create_event!(%{task_id: base_id, step: :work, cost_usd: 1.0, base_task_id: base_id, role: "base"})
      create_event!(%{task_id: review_id, step: :review, cost_usd: 2.0, base_task_id: base_id, role: "review"})

      assert Stats.task_costs_usd([base_id, review_id, untouched_id]) == %{
               base_id => 3.0,
               review_id => 2.0,
               untouched_id => 0.0
             }
    end
  end

  describe "base_task_id/role columns enable cost aggregation without suffix stripping" do
    test "task_costs_usd/1 uses base_task_id to sum all review/impl events under a base task" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"
      review_id = "#{base_id}#review"
      impl_id = "#{base_id}#review#impl1"

      create_event!(%{
        task_id: base_id,
        step: :work,
        cost_usd: 0.5,
        base_task_id: base_id,
        role: "base"
      })

      create_event!(%{
        task_id: review_id,
        step: :review,
        cost_usd: 0.3,
        base_task_id: base_id,
        role: "review"
      })

      create_event!(%{
        task_id: impl_id,
        step: :impl,
        cost_usd: 0.2,
        base_task_id: base_id,
        role: "impl"
      })

      assert %{^base_id => total} = Stats.task_costs_usd([base_id])
      assert_in_delta total, 1.0, 0.000001
    end

    test "task_costs_usd/1 resolves synthetic task_id to its own row, not the base rollup" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"
      review_id = "#{base_id}#review"

      create_event!(%{
        task_id: base_id,
        step: :work,
        cost_usd: 1.0,
        base_task_id: base_id,
        role: "base"
      })

      create_event!(%{
        task_id: review_id,
        step: :review,
        cost_usd: 2.0,
        base_task_id: base_id,
        role: "review"
      })

      assert Stats.task_costs_usd([review_id]) == %{review_id => 2.0}
    end

    test "task_costs_usd/1 with mixed base and synthetic ids resolves each independently" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"
      review_id = "#{base_id}#review"
      untouched_id = "bd-stats-untouched-#{System.unique_integer([:positive])}"

      create_event!(%{
        task_id: base_id,
        step: :work,
        cost_usd: 1.0,
        base_task_id: base_id,
        role: "base"
      })

      create_event!(%{
        task_id: review_id,
        step: :review,
        cost_usd: 2.0,
        base_task_id: base_id,
        role: "review"
      })

      assert Stats.task_costs_usd([base_id, review_id, untouched_id]) == %{
               base_id => 3.0,
               review_id => 2.0,
               untouched_id => 0.0
             }
    end

    test "resumed_from_run_id lineage: full spend aggregates across initial and resumed runs" do
      base_id = "bd-stats-#{System.unique_integer([:positive])}"

      # Create events for the initial run
      create_event!(%{
        task_id: base_id,
        step: :work,
        cost_usd: 0.5,
        base_task_id: base_id,
        role: "base"
      })

      create_event!(%{
        task_id: "#{base_id}#review",
        step: :review,
        cost_usd: 0.3,
        base_task_id: base_id,
        role: "review"
      })

      # Create events for the resumed run (same base_task_id)
      create_event!(%{
        task_id: base_id,
        step: :work,
        cost_usd: 0.2,
        base_task_id: base_id,
        role: "base"
      })

      assert %{^base_id => total} = Stats.task_costs_usd([base_id])
      assert_in_delta total, 1.0, 0.000001
    end
  end
end
