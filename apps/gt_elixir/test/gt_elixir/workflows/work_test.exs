defmodule GtElixir.Workflows.WorkTest do
  use GtElixir.DataCase, async: false

  alias GtElixir.Beads.{Issue, Workspace}
  alias GtElixir.Workflow
  alias GtElixir.Workflows.Work

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "work-test-ws", prefix: "wt"})
    {:ok, ws: ws}
  end

  describe "workflow declaration" do
    test "steps/0 returns the 5 steps in order" do
      assert Work.steps() == [:load_context, :design, :implement, :pre_verify, :submit]
    end

    test "vars/0 includes :bead_id, :worktree_path, :rig" do
      vars = Work.vars()
      for v <- [:bead_id, :worktree_path, :rig], do: assert(v in vars)
    end

    test "step_definition/1 returns the expected shape" do
      assert %{description: _, needs: [], vars: vars} = Work.step_definition(:load_context)
      assert :bead_id in vars

      assert %{needs: [:load_context]} = Work.step_definition(:design)
      assert %{needs: [:design]} = Work.step_definition(:implement)
      assert %{needs: [:implement]} = Work.step_definition(:pre_verify)
      assert %{needs: [:pre_verify]} = Work.step_definition(:submit)
    end
  end

  describe "run_step/2 — :load_context" do
    test "loads the bead and stores it in state", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "T", workspace_id: ws.id})

      assert {:ok, state} =
               Work.run_step(:load_context, %{
                 bead_id: bead.id,
                 worktree_path: "/tmp/x",
                 rig: "test/rig"
               })

      assert state.bead.id == bead.id
    end

    test "missing bead returns {:error, _}" do
      assert {:error, _} =
               Work.run_step(:load_context, %{
                 bead_id: "wt-doesnotexist",
                 worktree_path: "/tmp/x",
                 rig: "test/rig"
               })
    end
  end

  describe "run_step/2 — middle steps are placeholders" do
    test "design / implement / pre_verify all succeed and mark progress" do
      assert {:ok, %{design_done: true}} = Work.run_step(:design, %{})
      assert {:ok, %{implement_done: true}} = Work.run_step(:implement, %{})
      assert {:ok, %{pre_verify_done: true}} = Work.run_step(:pre_verify, %{})
    end
  end

  describe "run_step/2 — :submit polymorphism" do
    test ":none-tracked beads no-op", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "T", workspace_id: ws.id, tracker_type: :none})

      assert {:ok, %{submit_result: :ok}} = Work.run_step(:submit, %{bead: bead})
    end

    test "missing :bead in state returns an error" do
      assert {:error, {:missing_bead, _}} = Work.run_step(:submit, %{})
    end

    test ":jira-tracked beads dispatch through the Jira adapter (config_missing path)" do
      # Without active Jira config, Tracker.Jira returns
      # {:error, %Error{kind: :config_missing}}. That propagates up as the
      # step's error.
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "Jira bead",
          workspace_id: ws_for_this_test(:ws).id,
          tracker_type: :jira,
          tracker_ref: "VR-1"
        })

      result = Work.run_step(:submit, %{bead: bead})
      assert match?({:error, _}, result)
    end

    defp ws_for_this_test(_) do
      # Helper: return a workspace for the current test process. We can't
      # share setup across describes cleanly without context propagation, so
      # just make a fresh one here.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "submit-jira-test-#{System.unique_integer([:positive])}",
          prefix: "wt"
        })

      ws
    end
  end

  describe "end-to-end Workflow.run/2" do
    test ":none-tracked bead runs all 5 steps", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "E2E", workspace_id: ws.id, tracker_type: :none})

      initial = %{
        bead_id: bead.id,
        worktree_path: "/tmp/work-e2e",
        rig: "test/rig"
      }

      assert {:ok, final} = Workflow.run(Work, initial)
      assert final.submit_result == :ok
      assert MapSet.subset?(MapSet.new(Work.steps()), MapSet.new(final.completed_steps))
    end
  end
end
