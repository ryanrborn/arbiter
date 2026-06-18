defmodule Arbiter.Polecat.DriverTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Driver
  alias Arbiter.Polecat.Sling
  alias Arbiter.TestWorkflows
  alias Arbiter.Workflows.Machine

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

      # The :close action's after_action hook tears the polecat down; once
      # the bead is closed it should no longer be registered or alive.
      assert Polecat.whereis(bead.id) == nil
      refute Process.alive?(polecat_pid)

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

      # Simulate Claude printing "arb done": advance polecat then complete it.
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

    # bd-d1jp4r: ticks must not consume budget while the polecat is parked at
    # :awaiting_review (Warden) or :awaiting_tribunal (Tribunal). A long acolyte
    # run + review gate was exhausting the 30-minute tick budget before the
    # Warden called Polecat.complete, leaving the bead stranded at :in_progress.
    test "does not count ticks while polecat is :awaiting_review", %{ws: ws} do
      alias Arbiter.Test.StubMerger
      StubMerger.reset()

      {:ok, bead} = Ash.create(Issue, %{title: "cd-ar-freeze", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      # max_ticks: 2 — would expire after 2 cycles in :running, but should NOT
      # expire while the polecat is parked at :awaiting_review.
      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 2,
          claude_driven: true
        )

      # Advance polecat to :running then open an MR to park it at :awaiting_review.
      # The StubMerger opens synchronously and the Warden polls on a long interval
      # so it won't call Polecat.complete during this test.
      :ok = Polecat.advance(polecat_pid, :running)

      {:ok, _mr_ref} =
        Polecat.open_mr(polecat_pid, "my-branch", "title", "body", %{
          adapter: StubMerger,
          interval_ms: 100_000,
          max_polls: :infinity
        })

      # Let the driver run several more cycles while status is :awaiting_review.
      # With the fix, ticks don't increment here, so max_ticks: 2 won't fire.
      Process.sleep(60)

      assert Process.alive?(driver_pid),
             "driver should still be alive (ticks frozen at :awaiting_review)"

      # Now simulate the Warden calling Polecat.complete.
      :ok = Polecat.complete(polecat_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Bead must be closed — driver noticed :completed and closed it.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end

    # bd-d1jp4r: driver must close the bead even when max_ticks fires at the
    # exact moment the polecat transitions to :completed (the Warden race).
    test "closes the bead at max_ticks if polecat is already :completed", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "cd-maxtick-done", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      # Complete the polecat BEFORE the driver even starts — simulates the Warden
      # completing the polecat in the same moment max_ticks fires.
      :ok = Polecat.advance(polecat_pid, :running)
      :ok = Polecat.complete(polecat_pid, :merged)

      # Start the driver with max_ticks: 0 so it fires the max_ticks guard on
      # the very first check_polecat message.
      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Even though max_ticks was hit, bead must be closed because polecat was :completed.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end

    # bd-7b46wd: if the tick budget is exhausted by active acolyte work and the
    # max_ticks guard fires while the polecat has *already handed off* to the
    # Warden (:awaiting_review) or Tribunal (:awaiting_tribunal), the driver must
    # NOT stop — those states are owned by watchdogs that will drive the polecat
    # to terminal. Stopping here was stranding beads that were legitimately
    # mid-merge, and the bd-d1jp4r fix only covered the already-:completed case.
    test "keeps waiting at max_ticks while polecat is :awaiting_review, then closes", %{ws: ws} do
      alias Arbiter.Test.StubMerger
      StubMerger.reset()

      {:ok, bead} = Ash.create(Issue, %{title: "cd-maxtick-awaiting", workspace_id: ws.id})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, bead.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      # Park the polecat at :awaiting_review with a Warden that won't poll during
      # the test (long interval), so completion is driven explicitly below.
      :ok = Polecat.advance(polecat_pid, :running)

      {:ok, _mr_ref} =
        Polecat.open_mr(polecat_pid, "my-branch", "title", "body", %{
          adapter: StubMerger,
          interval_ms: 100_000,
          max_polls: :infinity
        })

      # max_ticks: 0 → the t >= m guard fires on the very first check. With the
      # polecat at :awaiting_review the driver must reschedule, not stop.
      {:ok, driver_pid} =
        Driver.start(
          bead_id: bead.id,
          polecat_pid: polecat_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      Process.sleep(40)

      assert Process.alive?(driver_pid),
             "driver must keep waiting at max_ticks while polecat is externally owned"

      {:ok, %Issue{status: :in_progress}} = Ash.get(Issue, bead.id)

      # The Warden (here, us) completes the polecat — the driver's next guarded
      # check must close the bead rather than stranding it.
      :ok = Polecat.complete(polecat_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
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

      # Worktree.create fetches from origin/<base>; provide a bare upstream.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "wt")
      File.mkdir_p!(worktree_root)

      prior_wt = Application.get_env(:arbiter, :worktree_root)
      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt),
          else: Application.delete_env(:arbiter, :worktree_root)

        File.rm_rf!(tmp)
      end)

      # Create a real worktree we can verify is gone after.
      {:ok, wt_path} = Arbiter.Polecat.Worktree.create(repo, "feature/dt-test", "main")

      %{wt_path: wt_path}
    end

    test "removes the worktree on successful completion when opted in", %{
      ws: ws,
      wt_path: wt_path
    } do
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
      {:ok, false} = Arbiter.Polecat.Worktree.has_uncommitted?(wt_path)
      {:ok, true} = Arbiter.Polecat.Worktree.has_commits_ahead?(wt_path, "main")

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

  describe "Warden auto-close (Bd-191)" do
    test "closes bead when polecat completes with an mr_ref (Warden merge)", %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "warden-close",
          workspace_id: ws.id
        })

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
          interval_ms: 5,
          claude_driven: true
        )

      # Simulate a polecat completion with mr_ref (from Warden merge)
      :ok = Polecat.advance(polecat_pid, :running)
      # Directly set the mr_ref via the polecat's meta to simulate Warden completion
      :ok = Polecat.report(polecat_pid, :mr_ref, "direct:test-branch")
      # Now complete the polecat
      :ok = Polecat.complete(polecat_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end
end
