defmodule Arbiter.Worker.StatsTest do
  use Arbiter.DataCase, async: true

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
      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.5})
      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.25})

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

      create_event!(%{task_id: task_id, step: :work, cost_usd: 0.741102})
      create_event!(%{task_id: "#{task_id}#review", step: :review, cost_usd: 0.6449235})
      create_event!(%{task_id: "#{task_id}#review#impl1", step: :impl, cost_usd: 0.0833313})
      create_event!(%{task_id: "#{task_id}#r2", step: :review, cost_usd: 0.4209582})

      assert %{^task_id => total} = Stats.task_costs_usd([task_id])
      assert_in_delta total, 1.890315, 0.000001
    end

    test "does not leak one task's rows into another task's total" do
      task_a = "bd-stats-a-#{System.unique_integer([:positive])}"
      task_b = "bd-stats-b-#{System.unique_integer([:positive])}"

      create_event!(%{task_id: task_a, step: :work, cost_usd: 1.0})
      create_event!(%{task_id: "#{task_b}#review", step: :review, cost_usd: 2.0})

      assert Stats.task_costs_usd([task_a]) == %{task_a => 1.0}
    end
  end
end
