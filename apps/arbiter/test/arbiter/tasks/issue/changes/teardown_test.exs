defmodule Arbiter.Tasks.Issue.Changes.TeardownTest do
  @moduledoc """
  Covers the after-action hooks wired into `Arbiter.Tasks.Issue`'s `:close`
  action:

    * `StopWorker` — tear down the running worker, if any.
    * `CleanupWorktree` — remove the task's worktree, if any (and clean).

  Both must be best-effort: a missing worker or worktree is a no-op; a
  dirty worktree is preserved.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Worktree

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "teardown-ws", prefix: "td"})
    {:ok, ws: ws}
  end

  describe "StopWorker after_action" do
    test "stops the worker registered for the task when :close fires", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "with worker", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      assert Worker.whereis(task.id) == worker_pid

      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      # Synchronous teardown: by the time :close returns, the worker is
      # unregistered and the process is dead.
      assert Worker.whereis(task.id) == nil
      refute Process.alive?(worker_pid)
    end

    test "is a silent no-op when no worker is registered", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no worker", workspace_id: ws.id})

      assert Worker.whereis(task.id) == nil
      assert {:ok, closed} = Ash.update(task, %{}, action: :close)
      assert closed.status == :closed
    end
  end

  describe "CleanupWorktree after_action" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "td-cw-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      # Worktree.create now fetches from origin and branches from
      # origin/<base>; provide a bare upstream so it has somewhere to fetch.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "wt")
      File.mkdir_p!(worktree_root)

      prior = Application.get_env(:arbiter, :worktree_root)
      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :worktree_root, prior),
          else: Application.delete_env(:arbiter, :worktree_root)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "removes the worktree at the task's derived path on :close", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "clean wt", workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      {:ok, wt_path} = Worktree.create(repo, branch, "main")
      assert File.dir?(wt_path)

      {:ok, _} = Ash.update(task, %{status: :in_progress})
      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      refute File.dir?(wt_path)
    end

    test "is a silent no-op when no worktree exists at the derived path", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      refute File.dir?(Worktree.worktree_path(branch))

      assert {:ok, closed} = Ash.update(task, %{}, action: :close)
      assert closed.status == :closed
    end

    test "preserves a dirty worktree and lets :close succeed", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "dirty wt", workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      {:ok, wt_path} = Worktree.create(repo, branch, "main")
      File.write!(Path.join(wt_path, "scratch.txt"), "wip\n")

      {:ok, _} = Ash.update(task, %{status: :in_progress})
      assert {:ok, closed} = Ash.update(task, %{}, action: :close)
      assert closed.status == :closed

      # Uncommitted work is preserved for operator inspection.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "scratch.txt"))
    end

    # bd-9r1tta: a `task`-type audit runs in a *detached* checkout at its own
    # leaf. Close must reclaim that leaf too, or the split leaks one worktree per
    # audited bead.
    test "removes the detached inspect worktree too", %{ws: ws, repo: repo} do
      {:ok, task} =
        Ash.create(Issue, %{title: "audit wt", issue_type: :task, workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      {:ok, inspect_path} = Worktree.create_detached(repo, Worktree.inspect_name(branch), "main")
      assert inspect_path == Worktree.inspect_path(branch)

      {:ok, _} = Ash.update(task, %{status: :in_progress})
      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      refute File.dir?(inspect_path)
    end

    # ... even when the agent left scratch files in it. Unlike a branch worktree,
    # a detached checkout has no branch and holds no deliverable, so there is
    # nothing to preserve.
    test "removes a dirty inspect worktree rather than leaking it", %{ws: ws, repo: repo} do
      {:ok, task} =
        Ash.create(Issue, %{title: "dirty audit wt", issue_type: :task, workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      {:ok, inspect_path} = Worktree.create_detached(repo, Worktree.inspect_name(branch), "main")
      File.write!(Path.join(inspect_path, "scratch.txt"), "audit scratch\n")

      {:ok, _} = Ash.update(task, %{status: :in_progress})
      assert {:ok, closed} = Ash.update(task, %{}, action: :close)
      assert closed.status == :closed

      refute File.dir?(inspect_path)
    end

    # The branch worktree's dirty-preserve rule is unaffected by the inspect
    # leaf's force-removal: both leaves are handled independently.
    test "preserves a dirty branch worktree while still reclaiming the inspect one",
         %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "both wts", workspace_id: ws.id})

      branch = BranchNamer.derive(task)
      {:ok, wt_path} = Worktree.create(repo, branch, "main")
      File.write!(Path.join(wt_path, "scratch.txt"), "wip\n")
      {:ok, inspect_path} = Worktree.create_detached(repo, Worktree.inspect_name(branch), "main")

      {:ok, _} = Ash.update(task, %{status: :in_progress})
      assert {:ok, _closed} = Ash.update(task, %{}, action: :close)

      assert File.exists?(Path.join(wt_path, "scratch.txt"))
      refute File.dir?(inspect_path)
    end
  end
end
