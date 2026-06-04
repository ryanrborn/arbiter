defmodule Arbiter.Beads.Issue.Changes.TeardownTest do
  @moduledoc """
  Covers the after-action hooks wired into `Arbiter.Beads.Issue`'s `:close`
  action:

    * `StopPolecat` — tear down the running polecat, if any.
    * `CleanupWorktree` — remove the bead's worktree, if any (and clean).

  Both must be best-effort: a missing polecat or worktree is a no-op; a
  dirty worktree is preserved.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Polecat.BranchNamer
  alias Arbiter.Polecat.Worktree

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "teardown-ws", prefix: "td"})
    {:ok, ws: ws}
  end

  describe "StopPolecat after_action" do
    test "stops the polecat registered for the bead when :close fires", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "with polecat", workspace_id: ws.id})
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      assert Polecat.whereis(bead.id) == polecat_pid

      {:ok, _closed} = Ash.update(bead, %{}, action: :close)

      # Synchronous teardown: by the time :close returns, the polecat is
      # unregistered and the process is dead.
      assert Polecat.whereis(bead.id) == nil
      refute Process.alive?(polecat_pid)
    end

    test "is a silent no-op when no polecat is registered", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no polecat", workspace_id: ws.id})

      assert Polecat.whereis(bead.id) == nil
      assert {:ok, closed} = Ash.update(bead, %{}, action: :close)
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

    test "removes the worktree at the bead's derived path on :close", %{ws: ws, repo: repo} do
      {:ok, bead} = Ash.create(Issue, %{title: "clean wt", workspace_id: ws.id})

      branch = BranchNamer.derive(bead)
      {:ok, wt_path} = Worktree.create(repo, branch, "main")
      assert File.dir?(wt_path)

      {:ok, _} = Ash.update(bead, %{status: :in_progress})
      {:ok, _closed} = Ash.update(bead, %{}, action: :close)

      refute File.dir?(wt_path)
    end

    test "is a silent no-op when no worktree exists at the derived path", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      branch = BranchNamer.derive(bead)
      refute File.dir?(Worktree.worktree_path(branch))

      assert {:ok, closed} = Ash.update(bead, %{}, action: :close)
      assert closed.status == :closed
    end

    test "preserves a dirty worktree and lets :close succeed", %{ws: ws, repo: repo} do
      {:ok, bead} = Ash.create(Issue, %{title: "dirty wt", workspace_id: ws.id})

      branch = BranchNamer.derive(bead)
      {:ok, wt_path} = Worktree.create(repo, branch, "main")
      File.write!(Path.join(wt_path, "scratch.txt"), "wip\n")

      {:ok, _} = Ash.update(bead, %{status: :in_progress})
      assert {:ok, closed} = Ash.update(bead, %{}, action: :close)
      assert closed.status == :closed

      # Uncommitted work is preserved for operator inspection.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "scratch.txt"))
    end
  end
end
