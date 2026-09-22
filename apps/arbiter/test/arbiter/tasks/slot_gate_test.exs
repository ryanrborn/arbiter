defmodule Arbiter.Tasks.SlotGateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.SlotGate

  defp worker(task_id, status, attrs \\ %{}) do
    Map.merge(
      %{task_id: task_id, registry_key: task_id, status: status, role: nil, meta: %{}},
      attrs
    )
  end

  describe "occupies_slot?/2 on the :agents basis" do
    test "a live agent session occupies a slot whatever the record's status says" do
      for status <- [
            :idle,
            :resuming,
            :running,
            :awaiting,
            :awaiting_review_gate,
            :awaiting_review
          ] do
        assert SlotGate.occupies_slot?(worker("bd-1", status, %{agent_live: true}), :agents),
               "#{status} with a live agent should hold a slot"
      end
    end

    test "a record with no live agent occupies no slot, including :awaiting" do
      for status <- [
            :idle,
            :resuming,
            :running,
            :awaiting,
            :awaiting_review_gate,
            :awaiting_review
          ] do
        refute SlotGate.occupies_slot?(worker("bd-1", status, %{agent_live: false}), :agents),
               "#{status} without a live agent should hold no slot"
      end
    end

    test "every role counts, not just the author" do
      for role <- [nil, :reviewer, :implementer, :fix_pass, :conflict_resolver] do
        assert SlotGate.occupies_slot?(
                 worker("bd-1", :running, %{role: role, agent_live: true}),
                 :agents
               ),
               "#{inspect(role)} with a live agent should hold a slot"
      end
    end

    test "unknown liveness degrades to the legacy status rule rather than to 'free'" do
      # A caller that cannot answer the liveness question (no :agent_live key)
      # must not have its workers silently counted as free — that would
      # over-dispatch. It falls back to the pre-bd-aw2cyt status test.
      assert SlotGate.occupies_slot?(worker("bd-1", :running), :agents)
      refute SlotGate.occupies_slot?(worker("bd-1", :awaiting_review), :agents)
    end
  end

  describe "occupies_slot?/2 on the :issues basis" do
    test "reproduces the pre-bd-aw2cyt rule: author records in a live status" do
      assert SlotGate.occupies_slot?(worker("bd-1", :running, %{agent_live: false}), :issues)
      assert SlotGate.occupies_slot?(worker("bd-1", :awaiting, %{agent_live: false}), :issues)

      refute SlotGate.occupies_slot?(
               worker("bd-1", :awaiting_review, %{agent_live: true}),
               :issues
             )
    end

    test "a reviewer / implementer pass folds into its author and holds nothing of its own" do
      refute SlotGate.occupies_slot?(
               worker("bd-1#review", :running, %{role: :reviewer, agent_live: true}),
               :issues
             )

      refute SlotGate.occupies_slot?(
               worker("bd-1#review#impl1", :running, %{role: :implementer, agent_live: true}),
               :issues
             )
    end
  end

  describe "occupied/2" do
    test "counts live agents across every role" do
      workers = [
        worker("bd-1", :awaiting_review, %{agent_live: false}),
        worker("bd-1", :running, %{role: :fix_pass, agent_live: true}),
        worker("bd-2#review", :running, %{role: :reviewer, agent_live: true}),
        worker("bd-2", :awaiting_review_gate, %{agent_live: false}),
        worker("bd-3", :awaiting, %{agent_live: false})
      ]

      assert SlotGate.occupied(workers, :agents) == 2
      # The old rule saw three author records instead.
      assert SlotGate.occupied(workers, :issues) == 3
    end
  end

  describe "free/3" do
    test "never reports a negative number of slots" do
      workers = for i <- 1..5, do: worker("bd-#{i}", :running, %{agent_live: true})
      assert SlotGate.free(2, workers, :agents) == 0
      assert SlotGate.free(8, workers, :agents) == 3
    end
  end

  describe "basis/0" do
    test "defaults to :agents" do
      assert SlotGate.basis() == :agents
    end

    test "honours the conductor.slot_basis application setting" do
      prev = Application.get_env(:arbiter, :conductor_slot_basis)
      on_exit(fn -> restore_env(prev) end)

      Application.put_env(:arbiter, :conductor_slot_basis, :issues)
      assert SlotGate.basis() == :issues

      Application.put_env(:arbiter, :conductor_slot_basis, "issues")
      assert SlotGate.basis() == :issues

      # A typo'd value is not config: fall back to the default rather than
      # silently adopting something nobody asked for.
      Application.put_env(:arbiter, :conductor_slot_basis, "nonsense")
      assert SlotGate.basis() == :agents
    end
  end

  defp restore_env(nil), do: Application.delete_env(:arbiter, :conductor_slot_basis)
  defp restore_env(v), do: Application.put_env(:arbiter, :conductor_slot_basis, v)
end
