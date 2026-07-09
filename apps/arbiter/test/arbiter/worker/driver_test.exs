defmodule Arbiter.Worker.DriverTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.Dispatch
  alias Arbiter.TestWorkflows
  alias Arbiter.Workflows.Machine

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "driver-test-ws", prefix: "dt"})
    {:ok, ws: ws}
  end

  describe "tick → completed" do
    test "drives a Three workflow to :completed and closes the task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "three", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)

      # Move task to :in_progress so :close is a legal transition.
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Machine.status(machine_pid) == :completed

      # The :close action's after_action hook tears the worker down; once
      # the task is closed it should no longer be registered or alive.
      assert Worker.whereis(task.id) == nil
      refute Process.alive?(worker_pid)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end
  end

  describe "tick → failed" do
    test "marks worker :failed and leaves task :in_progress on workflow error", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Failing, task.id, %{})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.status == :failed

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end
  end

  describe "max_ticks backstop" do
    test "stops and fails the worker when max_ticks is exceeded", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "loop", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          max_ticks: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.status == :failed
      assert match?({:driver_timeout, 1}, worker_snap.meta[:failure_reason])
    end
  end

  describe "monitor: machine dies mid-run" do
    test "marks worker :failed when the machine process dies", %{ws: ws} do
      # Machine.start uses start_link, so killing it would crash this test
      # process via the link. Trap exits to convert that into a message.
      Process.flag(:trap_exit, true)

      {:ok, task} = Ash.create(Issue, %{title: "mdied", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      # Pause the machine so the driver doesn't race us to completion.
      :ok = Machine.pause(machine_pid)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 10
        )

      ref = Process.monitor(driver_pid)

      # Kill the machine; driver should observe :DOWN and stop.
      Process.exit(machine_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.status == :failed
      assert worker_snap.meta[:failure_reason] == :machine_died
    end
  end

  describe "integration via Dispatch" do
    test "Dispatch with default opts starts a driver that closes the task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "via-dispatch", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "r", interval_ms: 1)
      assert is_pid(result.driver_pid)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end
  end

  describe "claude_driven mode" do
    test "closes the task when the worker transitions to :completed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-complete", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      # Driver should NOT have ticked the workflow — Machine stays :idle.
      Process.sleep(50)
      assert Machine.status(machine_pid) == :idle

      # Simulate Claude printing "arb done": advance worker then complete it.
      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :claude_done)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end

    test "leaves the task :in_progress when the worker transitions to :failed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      :ok = Worker.fail(worker_pid, :claude_crashed)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end

    test "max_ticks backstop stops the driver if the worker never completes", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-stuck", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 3,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Task stays :in_progress; we didn't close because worker didn't complete.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end

    # bd-d1jp4r: ticks must not consume budget while the worker is parked at
    # :awaiting_review (Watchdog) or :awaiting_review_gate (ReviewGate). A long worker
    # run + review gate was exhausting the 30-minute tick budget before the
    # Watchdog called Worker.complete, leaving the task stranded at :in_progress.
    test "does not count ticks while worker is :awaiting_review", %{ws: ws} do
      alias Arbiter.Test.StubMerger
      StubMerger.reset()

      {:ok, task} = Ash.create(Issue, %{title: "cd-ar-freeze", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      # max_ticks: 2 — would expire after 2 cycles in :running, but should NOT
      # expire while the worker is parked at :awaiting_review.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 2,
          claude_driven: true
        )

      # Advance worker to :running then open an MR to park it at :awaiting_review.
      # The StubMerger opens synchronously and the Watchdog polls on a long interval
      # so it won't call Worker.complete during this test.
      :ok = Worker.advance(worker_pid, :running)

      {:ok, _mr_ref} =
        Worker.open_mr(worker_pid, "my-branch", "title", "body", %{
          adapter: StubMerger,
          interval_ms: 100_000,
          max_polls: :infinity
        })

      # Let the driver run several more cycles while status is :awaiting_review.
      # With the fix, ticks don't increment here, so max_ticks: 2 won't fire.
      Process.sleep(60)

      assert Process.alive?(driver_pid),
             "driver should still be alive (ticks frozen at :awaiting_review)"

      # Now simulate the Watchdog calling Worker.complete.
      :ok = Worker.complete(worker_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Task must be closed — driver noticed :completed and closed it.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end

    # bd-d1jp4r: driver must close the task even when max_ticks fires at the
    # exact moment the worker transitions to :completed (the Watchdog race).
    test "closes the task at max_ticks if worker is already :completed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-maxtick-done", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      # Complete the worker BEFORE the driver even starts — simulates the Watchdog
      # completing the worker in the same moment max_ticks fires.
      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :merged)

      # Start the driver with max_ticks: 0 so it fires the max_ticks guard on
      # the very first check_worker message.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Even though max_ticks was hit, task must be closed because worker was :completed.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end

    # bd-7b46wd: if the tick budget is exhausted by active worker work and the
    # max_ticks guard fires while the worker has *already handed off* to the
    # Watchdog (:awaiting_review) or ReviewGate (:awaiting_review_gate), the driver must
    # NOT stop — those states are owned by watchdogs that will drive the worker
    # to terminal. Stopping here was stranding tasks that were legitimately
    # mid-merge, and the bd-d1jp4r fix only covered the already-:completed case.
    test "keeps waiting at max_ticks while worker is :awaiting_review, then closes", %{ws: ws} do
      alias Arbiter.Test.StubMerger
      StubMerger.reset()

      {:ok, task} = Ash.create(Issue, %{title: "cd-maxtick-awaiting", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      # Park the worker at :awaiting_review with a Watchdog that won't poll during
      # the test (long interval), so completion is driven explicitly below.
      :ok = Worker.advance(worker_pid, :running)

      {:ok, _mr_ref} =
        Worker.open_mr(worker_pid, "my-branch", "title", "body", %{
          adapter: StubMerger,
          interval_ms: 100_000,
          max_polls: :infinity
        })

      # max_ticks: 0 → the t >= m guard fires on the very first check. With the
      # worker at :awaiting_review the driver must reschedule, not stop.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      Process.sleep(40)

      assert Process.alive?(driver_pid),
             "driver must keep waiting at max_ticks while worker is externally owned"

      {:ok, %Issue{status: :in_progress}} = Ash.get(Issue, task.id)

      # The Watchdog (here, us) completes the worker — the driver's next guarded
      # check must close the task rather than stranding it.
      :ok = Worker.complete(worker_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
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
      {:ok, wt_path} = Arbiter.Worker.Worktree.create(repo, "feature/dt-test", "main")

      %{wt_path: wt_path}
    end

    test "removes the worktree on successful completion when opted in", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
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
      {:ok, task} = Ash.create(Issue, %{title: "no-cw", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
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

      {:ok, task} = Ash.create(Issue, %{title: "dirty", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
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

    test "removes the worktree when the worker fails (claude_driven :failed path)", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      :ok = Worker.fail(worker_pid, :claude_crashed)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      refute File.dir?(wt_path)
    end

    test "kills a live agent before reaping the worktree — no orphaned agent in a deleted cwd (bd-7a0pi8)",
         %{ws: ws, wt_path: wt_path} do
      {:ok, task} = Ash.create(Issue, %{title: "cw-live-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      # A LIVE agent whose cwd is the worktree the Driver is about to reap. This
      # is the run-7abf4049 shape: the run gets failed while the agent process
      # is still alive. If teardown removes the worktree without stopping the
      # agent first, the agent keeps issuing commands in a deleted cwd.
      {:ok, port} =
        ClaudeSession.start(owner: worker_pid, worktree_path: wt_path, command: ["sh", "-c", "sleep 60"])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      :ok = Worker.fail(worker_pid, :no_commits_at_completion)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Worktree reaped AND the agent is dead — the agent can no longer run any
      # command against the deleted cwd.
      refute File.dir?(wt_path)

      {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      assert code != 0, "agent os process #{os_pid} should be dead after teardown"
    end

    test "skips cleanup when the worktree has commits ahead of base", %{ws: ws, wt_path: wt_path} do
      # Commit a new file in the worktree, then have a clean working tree.
      File.write!(Path.join(wt_path, "new.txt"), "claude wrote me\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "new.txt"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "claude contribution"])

      # Confirm the precondition: clean worktree, 1 commit ahead.
      {:ok, false} = Arbiter.Worker.Worktree.has_uncommitted?(wt_path)
      {:ok, true} = Arbiter.Worker.Worktree.has_commits_ahead?(wt_path, "main")

      {:ok, task} = Ash.create(Issue, %{title: "ahead", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
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

  describe "review_only long-lived engagement (bd-cw3w9p)" do
    test "Driver exits without closing the task when worker is review_only and reaches :completed",
         %{ws: ws} do
      # bd-cw3w9p: review_only tasks are long-lived ReviewPatrol engagements.
      # When the worker reaches :completed the Driver must stop but NOT call
      # close_task — the task remains :in_progress for future review cycles.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "rp-open",
          workspace_id: ws.id
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r", meta: %{review_only: true})
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :claude_done)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
    end
  end

  describe "Watchdog auto-close (Bd-191)" do
    test "closes task when worker completes with an mr_ref (Watchdog merge)", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "watchdog-close",
          workspace_id: ws.id
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      # Simulate a worker completion with mr_ref (from Watchdog merge)
      :ok = Worker.advance(worker_pid, :running)
      # Directly set the mr_ref via the worker's meta to simulate Watchdog completion
      :ok = Worker.report(worker_pid, :mr_ref, "direct:test-branch")
      # Now complete the worker
      :ok = Worker.complete(worker_pid, :merged)

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end
  end
end
