defmodule Arbiter.Worker.WorktreeTest do
  # async: false — we mutate Application env (`:worktree_root`).
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Worktree

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

    # A bare repo to push to, so we can actually exercise push/2 — and so
    # `origin/main` exists for the fetch-from-origin path in `create/3`.
    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

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

    test "nonexistent base branch aborts before branching from stale state",
         %{repo: repo} do
      # `git fetch origin does-not-exist` fails before we can attempt the
      # worktree-add — so the result is `:fetch_failed` (or
      # `:missing_origin_ref` if a host's git ever silently succeeds). Either
      # way: we MUST NOT fall back to the local ref.
      assert {:error, reason} = Worktree.create(repo, "feature/no-base", "does-not-exist")

      assert match?({:fetch_failed, _}, reason) or match?({:missing_origin_ref, _}, reason),
             "expected fetch_failed or missing_origin_ref, got: #{inspect(reason)}"
    end

    test "aborts when the repo has no `origin` remote configured",
         %{tmp: tmp} do
      # Build a repo with NO origin remote. We MUST refuse to provision rather
      # than silently branching from the repo's (potentially stale) local base.
      local_only = Path.join(tmp, "local-only")
      File.mkdir_p!(local_only)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", local_only])
      {_, 0} = System.cmd("git", ["-C", local_only, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", local_only, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", local_only, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(local_only, "f"), "x")
      {_, 0} = System.cmd("git", ["-C", local_only, "add", "f"])
      {_, 0} = System.cmd("git", ["-C", local_only, "commit", "-q", "-m", "i"])

      assert {:error, {:missing_origin_remote, msg}} =
               Worktree.create(local_only, "feature/local-only", "main")

      assert msg =~ "origin"
    end

    test "fetches origin: worktree starts from upstream tip, NOT the repo's stale local base",
         %{repo: repo, remote: remote, tmp: tmp} do
      # Simulate the failure case from the bead: the repo's local `main` is
      # behind origin/main. A second clone advances origin; the repo's local
      # `main` stays put. The new worktree must start from origin/main (sees
      # the new file), not from the stale local ref.
      clone = Path.join(tmp, "advance-clone")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "UPSTREAM_ADVANCE.md"), "added on origin\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "UPSTREAM_ADVANCE.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance origin"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      # The repo's local `main` has NOT been fetched yet — it's stale.
      refute File.exists?(Path.join(repo, "UPSTREAM_ADVANCE.md"))

      assert {:ok, path} = Worktree.create(repo, "feature/from-upstream", "main")

      # Worktree saw the upstream advance — proves we cut from origin/main,
      # not from the stale local `main`.
      assert File.exists?(Path.join(path, "UPSTREAM_ADVANCE.md"))
    end

    test "dirty repo working tree does not block worktree provisioning",
         %{repo: repo} do
      # Per the bead's guards: the repo is read but a separate worktree is
      # created, so a dirty repo must NOT prevent provisioning.
      File.write!(Path.join(repo, "scratch.txt"), "wip in repo\n")

      assert {:ok, path} = Worktree.create(repo, "feature/dirty-repo", "main")
      assert File.dir?(path)
      assert {:ok, "feature/dirty-repo"} = Worktree.current_branch(path)
    end

    test "fetches origin even when the repo's HEAD is on an unrelated branch",
         %{repo: repo} do
      # The repo's HEAD is on a side branch — `main` exists but the working
      # tree is checked out elsewhere. The new worktree should still start
      # from `origin/main`, not blow up over the repo's HEAD state.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "repo-side"])
      File.write!(Path.join(repo, "SIDE.md"), "side branch\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "SIDE.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "side"])

      assert {:ok, path} = Worktree.create(repo, "feature/from-main", "main")

      # The new worktree is on `main`, not the repo's `repo-side`.
      assert {:ok, "feature/from-main"} = Worktree.current_branch(path)
      refute File.exists?(Path.join(path, "SIDE.md"))
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

    # Regression for bd-dg0gs6 / #172: per-bead worktrees symlink `deps`
    # (and sometimes `_build`) to a shared cache. The repo's directory-only
    # `/deps/` `/_build/` ignore patterns don't match a symlink, so git emits
    # `?? deps` — which previously false-tripped the commit gate on committed
    # work. A worktree whose only untracked entries are those artifact roots
    # must read as clean.
    test "ignores leaked deps/_build artifact entries", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/artifacts", "main")
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A `deps` symlink (as the real worktree setup creates) and an untracked
      # `_build` dir — both should be disregarded.
      File.ln_s!(System.tmp_dir!(), Path.join(path, "deps"))
      File.mkdir_p!(Path.join(path, "_build/dev"))
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A genuine untracked source file still counts as dirty.
      File.write!(Path.join(path, "lib_real.ex"), "defmodule X do end\n")
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
      assert [] =
               Worktree.list("/tmp/definitely-not-a-repo-#{:erlang.unique_integer([:positive])}")
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
