defmodule Arbiter.Workflows.MachineTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.TestWorkflows
  alias Arbiter.Workflows.Machine
  alias Arbiter.Workflows.MachineState

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "wf-test-ws", prefix: "wf"})
    {:ok, issue} = Ash.create(Issue, %{title: "wf bead", workspace_id: ws.id})
    {:ok, ws: ws, issue: issue}
  end

  defp attach(issue, vars),
    do: Machine.attach(TestWorkflows.Three, issue.id, vars)

  defp attach_and_start(issue, vars \\ %{}) do
    {:ok, id} = attach(issue, vars)
    {:ok, pid} = Machine.start(id)
    %{id: id, pid: pid}
  end

  describe "attach/3" do
    test "creates a MachineState row in :idle with current_step set to first step",
         %{issue: issue} do
      {:ok, id} = attach(issue, %{x: "hello"})

      {:ok, row} = Ash.get(MachineState, id)
      assert row.bead_id == issue.id
      assert row.status == :idle
      assert row.current_step == "a"
      assert row.completed_steps == []
      assert row.workflow_module == "Arbiter.TestWorkflows.Three"
      assert row.vars == %{"x" => "hello"}
      assert row.state == %{"x" => "hello"}
      assert row.error_reason == nil
    end

    test "rejects a module that does not implement Arbiter.Workflow", %{issue: issue} do
      assert {:error, :not_a_workflow} =
               Machine.attach(Arbiter.TestWorkflows.NotAWorkflow, issue.id, %{})
    end

    test "rejects a non-existent module", %{issue: issue} do
      assert {:error, :unknown_module} =
               Machine.attach(Arbiter.NoSuch.Module.Definitely, issue.id, %{})
    end
  end

  describe "start/1 + advance/1" do
    test "advance executes :a, current_step becomes :b", %{issue: issue} do
      %{id: id, pid: pid} = attach_and_start(issue, %{x: "hi"})

      assert {:ok, :b} = Machine.advance(pid)
      assert Machine.current_step(pid) == :b
      assert Machine.status(pid) == :running
      assert %{"a_done" => true} = Machine.state_data(pid)

      # Persisted to DB
      {:ok, row} = Ash.get(MachineState, id)
      assert row.current_step == "b"
      assert row.completed_steps == ["a"]
      assert row.status == :running
    end

    test "three sequential advances complete the workflow", %{issue: issue} do
      %{id: id, pid: pid} = attach_and_start(issue)

      assert {:ok, :b} = Machine.advance(pid)
      assert {:ok, :c} = Machine.advance(pid)
      assert {:ok, :completed} = Machine.advance(pid)
      assert Machine.status(pid) == :completed

      {:ok, row} = Ash.get(MachineState, id)
      assert row.status == :completed
      assert row.completed_steps == ["a", "b", "c"]
      assert row.current_step == "__done__"
    end

    test "advance after :completed returns {:error, :already_done}", %{issue: issue} do
      %{pid: pid} = attach_and_start(issue)
      {:ok, :b} = Machine.advance(pid)
      {:ok, :c} = Machine.advance(pid)
      {:ok, :completed} = Machine.advance(pid)
      assert {:error, :already_done} = Machine.advance(pid)
    end

    test "completed_steps populated correctly across advances (threading)", %{issue: issue} do
      %{pid: pid} = attach_and_start(issue)
      {:ok, :b} = Machine.advance(pid)
      assert %{"a_done" => true} = Machine.state_data(pid)
      {:ok, :c} = Machine.advance(pid)
      assert %{"a_done" => true, "b_done" => true} = Machine.state_data(pid)
      {:ok, :completed} = Machine.advance(pid)
      assert %{"a_done" => true, "b_done" => true, "c_done" => true} = Machine.state_data(pid)
    end
  end

  describe "failing steps" do
    test "a failing run_step sets status :failed and captures error_reason",
         %{issue: issue} do
      {:ok, id} = Machine.attach(TestWorkflows.Failing, issue.id, %{})
      {:ok, pid} = Machine.start(id)

      # First step succeeds
      assert {:ok, :boom} = Machine.advance(pid)
      # Second step fails
      assert {:error, :kaboom} = Machine.advance(pid)
      assert Machine.status(pid) == :failed

      {:ok, row} = Ash.get(MachineState, id)
      assert row.status == :failed
      assert row.error_reason =~ "kaboom"
    end
  end

  describe "pause / resume" do
    test "pause + advance returns {:error, :paused}; resume + advance proceeds",
         %{issue: issue} do
      %{pid: pid} = attach_and_start(issue)

      assert :ok = Machine.pause(pid)
      assert Machine.status(pid) == :paused
      assert {:error, :paused} = Machine.advance(pid)

      assert :ok = Machine.resume(pid)
      assert Machine.status(pid) == :running
      assert {:ok, :b} = Machine.advance(pid)
    end
  end

  describe "crash + restart" do
    test "killing the machine and starting again resumes at the same current_step",
         %{issue: issue} do
      %{id: id, pid: pid} = attach_and_start(issue, %{x: "v"})

      {:ok, :b} = Machine.advance(pid)
      assert Machine.current_step(pid) == :b

      # Unlink so the test process survives the kill (start/1 uses start_link
      # under the hood, which links the caller to the new machine).
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # Wait for registry cleanup
      assert eventually(fn -> Machine.whereis(id) == nil end)

      {:ok, new_pid} = Machine.start(id)
      assert Machine.current_step(new_pid) == :b
      assert Machine.status(new_pid) == :running
      assert %{"a_done" => true, "x" => "v"} = Machine.state_data(new_pid)

      # Can resume executing
      assert {:ok, :c} = Machine.advance(new_pid)
    end
  end

  describe "unmet needs" do
    test "forging completed_steps without the prereq surfaces {:error, {:unmet_needs, _}}",
         %{issue: issue} do
      {:ok, id} = attach(issue, %{x: "v"})

      # Forge the row: pretend we're "at step :b" without having done :a.
      {:ok, row} = Ash.get(MachineState, id)
      {:ok, _} = Ash.update(row, %{current_step: "b", completed_steps: []})

      {:ok, pid} = Machine.start(id)
      assert {:error, {:unmet_needs, [:a]}} = Machine.advance(pid)
    end
  end

  describe "registry / whereis" do
    test "whereis returns nil for unknown id and a pid for a running machine",
         %{issue: issue} do
      assert Machine.whereis("00000000-0000-0000-0000-000000000000") == nil

      %{id: id, pid: pid} = attach_and_start(issue)
      assert Machine.whereis(id) == pid
    end

    test "two machines for different beads coexist", %{ws: ws, issue: issue1} do
      {:ok, issue2} = Ash.create(Issue, %{title: "second", workspace_id: ws.id})

      %{id: id1, pid: pid1} = attach_and_start(issue1)
      %{id: id2, pid: pid2} = attach_and_start(issue2)

      assert pid1 != pid2
      assert Machine.whereis(id1) == pid1
      assert Machine.whereis(id2) == pid2

      # And both can advance independently
      assert {:ok, :b} = Machine.advance(pid1)
      assert Machine.current_step(pid2) == :a
    end

    test "starting a machine that's already running returns {:error, {:already_started, pid}}",
         %{issue: issue} do
      %{id: id, pid: pid} = attach_and_start(issue)
      assert {:error, {:already_started, ^pid}} = Machine.start(id)
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp eventually(fun, attempts \\ 50, delay_ms \\ 10)
  defp eventually(_fun, 0, _delay_ms), do: false

  defp eventually(fun, attempts, delay_ms) do
    if fun.() do
      true
    else
      Process.sleep(delay_ms)
      eventually(fun, attempts - 1, delay_ms)
    end
  end
end
