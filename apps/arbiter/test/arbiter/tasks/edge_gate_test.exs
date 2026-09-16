defmodule Arbiter.Tasks.EdgeGateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.EdgeGate

  defp dep(type, from, to), do: %{type: type, from_issue_id: from, to_issue_id: to}
  defp issue(id, status), do: %{id: id, status: status}

  describe "edge type classification" do
    test "only depends_on/blocks gate ordering; conflicts_with is the mutex" do
      assert EdgeGate.gating_types() == [:depends_on, :blocks]
      assert EdgeGate.mutex_types() == [:conflicts_with]
    end

    test "parent_of, relates_to and discovered_from are non-gating" do
      assert Enum.sort(EdgeGate.non_gating_types()) ==
               [:discovered_from, :parent_of, :relates_to]
    end

    test "every Dependency type is classified exactly once" do
      all =
        EdgeGate.gating_types() ++ EdgeGate.mutex_types() ++ EdgeGate.non_gating_types()

      assert Enum.sort(all) == Enum.sort(Arbiter.Tasks.Dependency.types())
      assert Enum.uniq(all) == all
    end
  end

  describe "gate/1" do
    test "nothing to say: no edges, nothing claimed" do
      assert EdgeGate.gate(%{}) == :ok
      assert EdgeGate.gate(%{blocked_by: [], conflicts: [], claimed: []}) == :ok
    end

    test "an open gating blocker holds the task, de-duplicated and sorted" do
      assert EdgeGate.gate(%{blocked_by: ["bd-9", "bd-8", "bd-9"]}) ==
               {:blocked, {:waiting_on, ["bd-8", "bd-9"]}}
    end

    test "a conflicts_with peer that is claimed holds the task" do
      assert EdgeGate.gate(%{conflicts: ["bd-2"], claimed: ["bd-2"]}) ==
               {:blocked, {:conflicts_with, "bd-2"}}
    end

    test "a conflicts_with peer that is not claimed does not hold the task" do
      assert EdgeGate.gate(%{conflicts: ["bd-2"], claimed: ["bd-7"]}) == :ok
    end

    test "claimed accepts a MapSet or a map of id => label" do
      assert EdgeGate.gate(%{conflicts: ["bd-2"], claimed: MapSet.new(["bd-2"])}) ==
               {:blocked, {:conflicts_with, "bd-2"}}

      assert EdgeGate.gate(%{conflicts: ["bd-2"], claimed: %{"bd-2" => "running"}}) ==
               {:blocked, {:conflicts_with, "bd-2"}}
    end

    test "the named peer is deterministic when several conflict at once" do
      ctx = %{conflicts: ["bd-9", "bd-2", "bd-5"], claimed: ["bd-9", "bd-5"]}
      assert EdgeGate.gate(ctx) == {:blocked, {:conflicts_with, "bd-5"}}
    end

    test "an open blocker outranks a conflict — it survives the conflict clearing" do
      ctx = %{blocked_by: ["bd-9"], conflicts: ["bd-2"], claimed: ["bd-2"]}
      assert EdgeGate.gate(ctx) == {:blocked, {:waiting_on, ["bd-9"]}}
    end
  end

  describe "describe/1" do
    test "phrases both blocks the way the board already phrases waiting" do
      assert EdgeGate.describe({:waiting_on, ["bd-9"]}) == "waiting on bd-9"
      assert EdgeGate.describe({:waiting_on, ["bd-8", "bd-9"]}) == "waiting on bd-8, bd-9"
      assert EdgeGate.describe({:conflicts_with, "bd-2"}) == "conflicts with bd-2"
    end
  end

  describe "blockers/2" do
    test "depends_on targets and blocks sources that are not closed" do
      deps = [dep(:depends_on, "bd-1", "bd-2"), dep(:blocks, "bd-3", "bd-4")]

      issues = [
        issue("bd-1", :open),
        issue("bd-4", :open),
        issue("bd-2", :open),
        issue("bd-3", :open)
      ]

      assert EdgeGate.blockers(deps, issues) == %{"bd-1" => ["bd-2"], "bd-4" => ["bd-3"]}
    end

    test "a closed blocker stops blocking" do
      deps = [dep(:depends_on, "bd-1", "bd-2")]
      issues = [issue("bd-1", :open), issue("bd-2", :closed)]

      assert EdgeGate.blockers(deps, issues) == %{}
    end

    test "an awaiting_verification blocker still blocks its dependents" do
      deps = [dep(:depends_on, "bd-1", "bd-2")]
      issues = [issue("bd-1", :open), issue("bd-2", :awaiting_verification)]

      assert EdgeGate.blockers(deps, issues) == %{"bd-1" => ["bd-2"]}
    end

    test "non-gating edge types never block" do
      deps =
        for type <- [:relates_to, :discovered_from, :parent_of, :conflicts_with],
            do: dep(type, "bd-1", "bd-2")

      issues = [issue("bd-1", :open), issue("bd-2", :open)]

      assert EdgeGate.blockers(deps, issues) == %{}
    end
  end

  describe "conflict adjacency" do
    test "a single stored row is honoured in both directions" do
      adjacency = EdgeGate.conflict_adjacency([dep(:conflicts_with, "bd-1", "bd-2")])

      assert EdgeGate.conflicts(adjacency, "bd-1") == ["bd-2"]
      assert EdgeGate.conflicts(adjacency, "bd-2") == ["bd-1"]
      assert EdgeGate.conflicts(adjacency, "bd-3") == []
    end

    test "scoping to a member set drops edges running through a non-member" do
      deps = [dep(:conflicts_with, "bd-1", "bd-2"), dep(:conflicts_with, "bd-1", "bd-9")]
      adjacency = EdgeGate.conflict_adjacency(deps, ["bd-1", "bd-2"])

      assert EdgeGate.conflicts(adjacency, "bd-1") == ["bd-2"]
    end

    test "other edge types contribute nothing" do
      deps = [dep(:depends_on, "bd-1", "bd-2"), dep(:parent_of, "bd-1", "bd-3")]

      assert EdgeGate.conflict_adjacency(deps) == %{}
    end

    test "conflict_pairs/1 keeps only the mutex rows, as stored" do
      deps = [dep(:conflicts_with, "bd-1", "bd-2"), dep(:depends_on, "bd-3", "bd-4")]

      assert EdgeGate.conflict_pairs(deps) == [{"bd-1", "bd-2"}]
    end
  end
end
