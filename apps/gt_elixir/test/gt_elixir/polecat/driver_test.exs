defmodule GtElixir.Polecat.DriverTest do
  use GtElixir.DataCase, async: false

  alias GtElixir.Beads.Issue
  alias GtElixir.Beads.Workspace
  alias GtElixir.Polecat
  alias GtElixir.Polecat.Driver
  alias GtElixir.Polecat.Sling
  alias GtElixir.TestWorkflows
  alias GtElixir.Workflows.Machine

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "driver-test-ws", prefix: "dt"})
    {:ok, ws: ws}
  end

  describe "tick → completed" do
    test "drives a Three workflow to :completed and closes the bead", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "three", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)

      # Move bead to :in_progress so :close is a legal transition.
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Machine.status(machine_pid) == :completed

      polecat_snap = Polecat.state(polecat_pid)
      assert polecat_snap.status == :completed

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "tick → failed" do
    test "marks polecat :failed and leaves bead :in_progress on workflow error", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "fail", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Failing, bead.id, %{})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      polecat_snap = Polecat.state(polecat_pid)
      assert polecat_snap.status == :failed

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :in_progress
    end
  end

  describe "max_ticks backstop" do
    test "stops and fails the polecat when max_ticks is exceeded", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "loop", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          max_ticks: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      polecat_snap = Polecat.state(polecat_pid)
      assert polecat_snap.status == :failed
      assert match?({:driver_timeout, 1}, polecat_snap.meta[:failure_reason])
    end
  end

  describe "monitor: machine dies mid-run" do
    test "marks polecat :failed when the machine process dies", %{ws: ws} do
      # Machine.start uses start_link, so killing it would crash this test
      # process via the link. Trap exits to convert that into a message.
      Process.flag(:trap_exit, true)

      {:ok, bead} = Ash.create(Issue, %{title: "mdied", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      # Pause the machine so the driver doesn't race us to completion.
      :ok = Machine.pause(machine_pid)

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 10
        )

      ref = Process.monitor(driver_pid)

      # Kill the machine; driver should observe :DOWN and stop.
      Process.exit(machine_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      polecat_snap = Polecat.state(polecat_pid)
      assert polecat_snap.status == :failed
      assert polecat_snap.meta[:failure_reason] == :machine_died
    end
  end

  describe "integration via Sling" do
    test "Sling with default opts starts a driver that closes the bead", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "via-sling", workspace_id: ws.id})

      {:ok, result} = Sling.sling(bead.id, rig: "r", interval_ms: 1)
      assert is_pid(result.driver_pid)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end
end
