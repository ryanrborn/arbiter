defmodule Arbiter.Polecat.WorktreeTest do
  # async: false — we mutate Application env (`:worktree_root`).
  use ExUnit.Case, async: false

  alias Arbiter.Polecat.Worktree

  @env_key :worktree_root

  setup do
    unique = "gte009-#{:erlang.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), unique)
    File.mkdir_p!(tmp)

    repo = Path.join(tmp, "source")
    File.mkdir_p!(repo)

    # Build a minimal real git repo. Branch is named `main` explicitly so
    # tests don't depend on the host's `init.defaultBranch` config.
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

    # A bare repo to push to, so we can actually exercise push/2.
    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])

    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(worktree_root)

    prior =
      case Application.fetch_env(:arbiter, @env_key) do
        {:ok, v} -> {:set, v}
        :error -> :unset
      end

    Application.put_env(:arbiter, @env_key, worktree_root)

    on_exit(fn ->
      case prior do
        {:set, v} -> Application.put_env(:arbiter, @env_key, v)
        :unset -> Application.delete_env(:arbiter, @env_key)
      end

      File.rm_rf!(tmp)
    end)

    %{repo: repo, root: worktree_root, remote: remote, tmp: tmp}
  end

  describe "create/3" do
    test "creates a worktree at the predicted path on the requested branch", %{
      repo: repo,
      root: root
    } do
      assert {:ok, path} = Worktree.create(repo, "feature/test-a", "main")
      assert path == Path.join(root, "feature-test-a")
      assert File.dir?(path)
      assert {:ok, "feature/test-a"} = Worktree.current_branch(path)
    end

    test "is idempotent: second call with same args is a no-op", %{repo: repo} do
      assert {:ok, path1} = Worktree.create(repo, "feature/idem", "main")
      assert {:ok, path2} = Worktree.create(repo, "feature/idem", "main")
      assert path1 == path2
      assert File.dir?(path1)
    end

    test "empty branch name returns :invalid_branch_name", %{repo: repo} do
      assert {:error, :invalid_branch_name} = Worktree.create(repo, "", "main")
    end

    test "nil branch name returns :invalid_branch_name", %{repo: repo} do
      assert {:error, :invalid_branch_name} = Worktree.create(repo, nil, "main")
    end

    test "nonexistent base branch returns {:error, {:git_failed, _}}", %{repo: repo} do
      assert {:error, {:git_failed, msg}} =
               Worktree.create(repo, "feature/no-base", "does-not-exist")

      assert is_binary(msg)
      assert msg != ""
    end
  end

  describe "current_branch/1" do
    test "returns the branch the worktree was created on", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/cb", "main")
      assert {:ok, "feature/cb"} = Worktree.current_branch(path)
    end
  end

  describe "has_uncommitted?/1" do
    test "false on a clean worktree, true once a file is touched", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/dirty", "main")
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      File.write!(Path.join(path, "scratch.txt"), "wip\n")
      assert {:ok, true} = Worktree.has_uncommitted?(path)
    end
  end

  describe "cleanup/1" do
    test "removes the worktree directory and a second call is a no-op", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/clean", "main")
      assert File.dir?(path)

      assert :ok = Worktree.cleanup(path)
      refute File.exists?(path)

      # Second cleanup must not blow up.
      assert :ok = Worktree.cleanup(path)
    end

    test "cleanup on a path that never existed returns :ok", %{root: root} do
      ghost = Path.join(root, "never-existed")
      refute File.exists?(ghost)
      assert :ok = Worktree.cleanup(ghost)
    end
  end

  describe "push/2" do
    test "pushes the worktree's branch to origin and sets upstream", %{repo: repo, remote: remote} do
      {:ok, path} = Worktree.create(repo, "feature/push", "main")

      assert {:ok, _output} = Worktree.push(path, set_upstream: true)

      # Verify the remote has the branch.
      {out, 0} = System.cmd("git", ["-C", remote, "branch", "--list", "feature/push"])
      assert String.contains?(out, "feature/push")
    end

    test "push surfaces git errors for an unknown remote", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/push-fail", "main")
      assert {:error, {:git_failed, _}} = Worktree.push(path, remote: "nope")
    end
  end

  describe "list/1" do
    test "returns linked worktrees with branch names, excluding the main",
         %{repo: repo} do
      {:ok, a} = Worktree.create(repo, "feature/list-a", "main")
      {:ok, b} = Worktree.create(repo, "feature/list-b", "main")

      worktrees = Worktree.list(repo)

      assert length(worktrees) == 2
      paths = Enum.map(worktrees, & &1.path)
      assert a in paths
      assert b in paths

      branches = Enum.map(worktrees, & &1.branch)
      assert "feature/list-a" in branches
      assert "feature/list-b" in branches
    end

    test "returns [] when there are no linked worktrees", %{repo: repo} do
      assert [] = Worktree.list(repo)
    end

    test "returns [] for a non-existent path" do
      assert [] = Worktree.list("/tmp/definitely-not-a-repo-#{:erlang.unique_integer([:positive])}")
    end
  end

  describe "attach/2" do
    test "checks out an EXISTING branch into a worktree (no -b)", %{repo: repo, root: root} do
      # Create a branch in the repo without making a worktree for it.
      {_, 0} = System.cmd("git", ["-C", repo, "branch", "feature/exists"])

      assert {:ok, path} = Worktree.attach(repo, "feature/exists")
      assert path == Path.join(root, "feature-exists")
      assert File.dir?(path)
      assert {:ok, "feature/exists"} = Worktree.current_branch(path)
    end

    test "fails when the branch does NOT exist (this is the contract — no -b)", %{repo: repo} do
      assert {:error, {:git_failed, msg}} = Worktree.attach(repo, "feature/never-existed")
      assert is_binary(msg)
    end

    test "is idempotent on the same-branch path", %{repo: repo} do
      {_, 0} = System.cmd("git", ["-C", repo, "branch", "feature/attach-idem"])

      {:ok, p1} = Worktree.attach(repo, "feature/attach-idem")
      {:ok, p2} = Worktree.attach(repo, "feature/attach-idem")
      assert p1 == p2
    end

    test "empty / nil branch name returns :invalid_branch_name", %{repo: repo} do
      assert {:error, :invalid_branch_name} = Worktree.attach(repo, "")
      assert {:error, :invalid_branch_name} = Worktree.attach(repo, nil)
    end
  end
end
