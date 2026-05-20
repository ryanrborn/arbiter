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

  describe "claude_driven mode" do
    test "closes the bead when the polecat transitions to :completed", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "cd-complete", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      # Driver should NOT have ticked the workflow — Machine stays :idle.
      Process.sleep(50)
      assert Machine.status(machine_pid) == :idle

      # Simulate Claude printing "gt done": advance polecat then complete it.
      :ok = Polecat.advance(polecat_pid, :running)
      :ok = Polecat.complete(polecat_pid, :claude_done)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end

    test "leaves the bead :in_progress when the polecat transitions to :failed", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "cd-fail", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      :ok = Polecat.fail(polecat_pid, :claude_crashed)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :in_progress
    end

    test "max_ticks backstop stops the driver if the polecat never completes", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "cd-stuck", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 3,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Bead stays :in_progress; we didn't close because polecat didn't complete.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :in_progress
    end
  end

  describe "cleanup_worktree opt" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "drv-cw-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      worktree_root = Path.join(tmp, "wt")
      File.mkdir_p!(worktree_root)

      prior_wt = Application.get_env(:gt_elixir, :worktree_root)
      Application.put_env(:gt_elixir, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt,
          do: Application.put_env(:gt_elixir, :worktree_root, prior_wt),
          else: Application.delete_env(:gt_elixir, :worktree_root)

        File.rm_rf!(tmp)
      end)

      # Create a real worktree we can verify is gone after.
      {:ok, wt_path} = GtElixir.Polecat.Worktree.create(repo, "feature/dt-test", "main")

      %{wt_path: wt_path}
    end

    test "removes the worktree on successful completion when opted in", %{ws: ws, wt_path: wt_path} do
      {:ok, bead} = Ash.create(Issue, %{title: "cw", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
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
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      refute File.dir?(wt_path)
    end

    test "leaves the worktree alone by default", %{ws: ws, wt_path: wt_path} do
      {:ok, bead} = Ash.create(Issue, %{title: "no-cw", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
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
          worktree_path: wt_path
          # cleanup_worktree default: false
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert File.dir?(wt_path)
    end

    test "skips cleanup when the worktree has uncommitted changes", %{ws: ws, wt_path: wt_path} do
      # Make the worktree dirty.
      File.write!(Path.join(wt_path, "scratch.txt"), "dirty\n")

      {:ok, bead} = Ash.create(Issue, %{title: "dirty", workspace_id: ws.id})
      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
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
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Still there — uncommitted changes protect operator inspection.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "scratch.txt"))
    end

    test "skips cleanup when the worktree has commits ahead of base", %{ws: ws, wt_path: wt_path} do
      # Commit a new file in the worktree, then have a clean working tree.
      File.write!(Path.join(wt_path, "new.txt"), "claude wrote me\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "new.txt"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "claude contribution"])

      # Confirm the precondition: clean worktree, 1 commit ahead.
      {:ok, false} = GtElixir.Polecat.Worktree.has_uncommitted?(wt_path)
      {:ok, true} = GtElixir.Polecat.Worktree.has_commits_ahead?(wt_path, "main")

      {:ok, bead} = Ash.create(Issue, %{title: "ahead", workspace_id: ws.id})
      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
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
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Still there — committed-but-unpushed work is preserved.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "new.txt"))
    end
  end
end
