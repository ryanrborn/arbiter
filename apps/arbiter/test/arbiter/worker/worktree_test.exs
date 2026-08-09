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
      # Simulate the failure case from the task: the repo's local `main` is
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
      # Per the task's guards: the repo is read but a separate worktree is
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

  # bd-9r1tta: dispatches that produce no branch (task-type audits, reviews)
  # used to run straight from the shared local checkout — whatever HEAD a human
  # contributor happened to leave it on, however many commits behind origin.
  # `create_detached/3` gives them the same fetch-first guarantee `create/3`
  # gives code dispatches, without minting a branch they'd never push.
  describe "create_detached/3" do
    test "checks out origin/<base> detached, at the predicted path", %{repo: repo, root: root} do
      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-detach", "main")
      assert path == Path.join(root, "feature-bd-detach")
      assert File.dir?(path)

      # Detached: no branch, and HEAD is exactly origin/main's tip.
      assert {:ok, "HEAD"} = Worktree.current_branch(path)
      assert head_sha(path) == rev_parse(repo, "refs/remotes/origin/main")
    end

    test "fetches origin first, so a month-stale local checkout still gets current upstream",
         %{repo: repo, remote: remote, tmp: tmp} do
      # Advance origin/main behind the local checkout's back — the tonic
      # scenario: the local clone is a human's working dir, 72 commits behind.
      clone = Path.join(tmp, "detach-clone")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "ENCRYPTION.md"), "shipped upstream\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "ENCRYPTION.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "encrypt PHI at rest"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      refute File.exists?(Path.join(repo, "ENCRYPTION.md"))

      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-stale", "main")

      # The auditing agent sees the merged work — not the stale local tree.
      assert File.exists?(Path.join(path, "ENCRYPTION.md"))
    end

    test "never touches the source checkout's HEAD, branch, or working tree",
         %{repo: repo, remote: remote, tmp: tmp} do
      # The human's checkout: on a side branch, with unpushed commits AND
      # uncommitted work. None of it may be disturbed.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "human-wip"])
      File.write!(Path.join(repo, "unpushed.md"), "local commit\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "unpushed.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "unpushed local work"])
      File.write!(Path.join(repo, "dirty.md"), "uncommitted\n")

      head_before = head_sha(repo)

      clone = Path.join(tmp, "untouched-clone")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "REMOTE.md"), "upstream moved\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "REMOTE.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "upstream"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-untouched", "main")

      # Source checkout: same branch, same HEAD, dirty file intact, unpushed
      # commit intact.
      assert {:ok, "human-wip"} = Worktree.current_branch(repo)
      assert head_sha(repo) == head_before
      assert File.read!(Path.join(repo, "dirty.md")) == "uncommitted\n"
      assert File.exists?(Path.join(repo, "unpushed.md"))

      # ... while the detached checkout is at current upstream.
      assert File.exists?(Path.join(path, "REMOTE.md"))
      refute File.exists?(Path.join(path, "unpushed.md"))
    end

    test "is idempotent: a second call returns the existing path", %{repo: repo} do
      assert {:ok, path1} = Worktree.create_detached(repo, "feature/bd-idem", "main")
      assert {:ok, ^path1} = Worktree.create_detached(repo, "feature/bd-idem", "main")
      assert File.dir?(path1)
    end

    # Round-1 review finding: returning an existing directory as-is re-opened the
    # staleness hole on any re-dispatch. The leaf is keyed to the bead and the
    # worktree outlives its run (`CleanupWorktree` removes it only on close, and
    # skips a dirty one), so a re-dispatched audit read the FIRST dispatch's
    # snapshot of upstream — the same silently-wrong answer, shorter fuse.
    test "re-points an existing detached worktree at current upstream instead of reusing the old snapshot",
         %{repo: repo, remote: remote, tmp: tmp} do
      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-restale", "main")
      first_head = head_sha(path)
      refute File.exists?(Path.join(path, "LATER.md"))

      # Upstream moves after the first dispatch (and the local checkout, as
      # always, has not pulled).
      advance_origin!(tmp, remote, "LATER.md", "merged after the first audit\n")

      assert {:ok, ^path} = Worktree.create_detached(repo, "feature/bd-restale", "main")

      assert File.exists?(Path.join(path, "LATER.md"))
      assert head_sha(path) == rev_parse(repo, "refs/remotes/origin/main")
      refute head_sha(path) == first_head
      # Still detached — re-pointing must not mint a branch.
      assert {:ok, "HEAD"} = Worktree.current_branch(path)
    end

    test "re-points even when a prior agent left the tree dirty", %{
      repo: repo,
      remote: remote,
      tmp: tmp
    } do
      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-dirty", "main")
      File.write!(Path.join(path, "README.md"), "an agent scribbled here\n")
      File.write!(Path.join(path, "scratch.txt"), "notes\n")

      advance_origin!(tmp, remote, "AFTER_DIRTY.md", "upstream moved\n")

      assert {:ok, ^path} = Worktree.create_detached(repo, "feature/bd-dirty", "main")

      assert File.exists?(Path.join(path, "AFTER_DIRTY.md"))
      assert File.read!(Path.join(path, "README.md")) == "hello\n"
    end

    test "refuses to re-point a worktree that is on a branch", %{repo: repo} do
      # A branch worktree at the same leaf may hold unpushed commits — never
      # clobber it, even though nothing in an inspect tree is precious.
      assert {:ok, path} = Worktree.create(repo, "feature/bd-branchy", "main")

      assert {:error, {:git_failed, msg}} =
               Worktree.create_detached(repo, "feature/bd-branchy", "main")

      assert msg =~ "not a detached inspect checkout"
      assert {:ok, "feature/bd-branchy"} = Worktree.current_branch(path)
    end

    test "reclaims a leftover directory that is not a git worktree", %{repo: repo} do
      path = Worktree.worktree_path("feature/bd-leftover")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "junk.txt"), "not a worktree\n")

      assert {:ok, ^path} = Worktree.create_detached(repo, "feature/bd-leftover", "main")

      assert {:ok, "HEAD"} = Worktree.current_branch(path)
      assert File.exists?(Path.join(path, "README.md"))
      refute File.exists?(Path.join(path, "junk.txt"))
    end

    test "recovers when the leaf is still registered but its directory was deleted",
         %{repo: repo} do
      assert {:ok, path} = Worktree.create_detached(repo, "feature/bd-pruned", "main")

      # Delete the directory behind git's back: the registration in
      # `.git/worktrees` survives and makes a plain `worktree add` fail forever.
      File.rm_rf!(path)
      assert {:error, _} = Worktree.current_branch(path)

      assert {:ok, ^path} = Worktree.create_detached(repo, "feature/bd-pruned", "main")
      assert {:ok, "HEAD"} = Worktree.current_branch(path)
    end

    test "errors when the repo has no origin remote", %{tmp: tmp} do
      local = Path.join(tmp, "no-origin")
      File.mkdir_p!(local)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", local])
      {_, 0} = System.cmd("git", ["-C", local, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", local, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", local, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(local, "a.md"), "a\n")
      {_, 0} = System.cmd("git", ["-C", local, "add", "a.md"])
      {_, 0} = System.cmd("git", ["-C", local, "commit", "-q", "-m", "i"])

      assert {:error, {:missing_origin_remote, msg}} =
               Worktree.create_detached(local, "feature/bd-no-origin", "main")

      assert msg =~ "origin"
    end

    test "errors when the base branch does not exist on origin", %{repo: repo} do
      assert {:error, {:fetch_failed, _}} =
               Worktree.create_detached(repo, "feature/bd-no-base", "nonexistent-base")
    end

    test "rejects an empty or nil name", %{repo: repo} do
      assert {:error, :invalid_branch_name} = Worktree.create_detached(repo, "", "main")
      assert {:error, :invalid_branch_name} = Worktree.create_detached(repo, nil, "main")
    end
  end

  # Round-1 review finding: sharing one leaf between an inspect checkout and a
  # branch worktree made a later branch dispatch of the same bead hard-fail
  # ("worktree exists … on a different branch", which the `already exists` →
  # `attach/2` recovery does not match). Separate leaves make that impossible.
  describe "inspect_name/1 and inspect_path/1" do
    test "the inspect leaf is distinct from the branch leaf" do
      assert Worktree.inspect_name("feature/bd-x") == "feature/bd-x-inspect"

      assert Worktree.inspect_path("feature/bd-x") ==
               Worktree.worktree_path("feature/bd-x-inspect")

      refute Worktree.inspect_path("feature/bd-x") == Worktree.worktree_path("feature/bd-x")
    end

    test "an inspect checkout and a branch worktree for the same name coexist", %{repo: repo} do
      name = "feature/bd-both"

      assert {:ok, inspect_path} =
               Worktree.create_detached(repo, Worktree.inspect_name(name), "main")

      assert {:ok, branch_path} = Worktree.create(repo, name, "main")

      refute inspect_path == branch_path
      assert {:ok, "HEAD"} = Worktree.current_branch(inspect_path)
      assert {:ok, ^name} = Worktree.current_branch(branch_path)
    end
  end

  describe "detached?/1" do
    test "true for a detached checkout, false for a branch worktree", %{repo: repo} do
      {:ok, detached} = Worktree.create_detached(repo, "feature/bd-det-probe", "main")
      {:ok, branched} = Worktree.create(repo, "feature/bd-branch-probe", "main")

      assert {:ok, true} = Worktree.detached?(detached)
      assert {:ok, false} = Worktree.detached?(branched)
    end

    test "errors for a path that is not a git worktree", %{tmp: tmp} do
      plain = Path.join(tmp, "not-a-worktree")
      File.mkdir_p!(plain)
      assert {:error, _} = Worktree.detached?(plain)
    end
  end

  # bd-9r1tta: for callers that must keep a shared, human-used checkout as their
  # cwd (local code review) but still need `origin/<base>` to mean *current*
  # upstream rather than whenever the contributor last pulled.
  describe "fetch_origin/2" do
    test "advances the remote-tracking ref to current upstream", %{
      repo: repo,
      remote: remote,
      tmp: tmp
    } do
      before = rev_parse(repo, "refs/remotes/origin/main")

      clone = Path.join(tmp, "fetch-clone")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "NEW.md"), "upstream\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "NEW.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "upstream commit"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      assert :ok = Worktree.fetch_origin(repo, "main")

      assert rev_parse(repo, "refs/remotes/origin/main") == head_sha(clone)
      refute rev_parse(repo, "refs/remotes/origin/main") == before
    end

    test "refs only — leaves HEAD, the local branch, and the working tree alone",
         %{repo: repo, remote: remote, tmp: tmp} do
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "human-wip"])
      File.write!(Path.join(repo, "dirty.md"), "uncommitted\n")
      head_before = head_sha(repo)

      clone = Path.join(tmp, "refs-only-clone")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "REMOTE_ONLY.md"), "upstream\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "REMOTE_ONLY.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "upstream"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      assert :ok = Worktree.fetch_origin(repo, "main")

      assert {:ok, "human-wip"} = Worktree.current_branch(repo)
      assert head_sha(repo) == head_before
      assert File.read!(Path.join(repo, "dirty.md")) == "uncommitted\n"
      # The fetched commit is in the object store but not in the working tree.
      refute File.exists?(Path.join(repo, "REMOTE_ONLY.md"))
    end

    test "errors when the repo has no origin remote", %{tmp: tmp} do
      local = Path.join(tmp, "fetch-no-origin")
      File.mkdir_p!(local)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", local])

      assert {:error, {:missing_origin_remote, _}} = Worktree.fetch_origin(local, "main")
    end

    test "errors when the branch does not exist upstream", %{repo: repo} do
      assert {:error, {:fetch_failed, _}} = Worktree.fetch_origin(repo, "no-such-branch")
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

    # Regression for bd-dg0gs6 / #172. `seed_compiled_deps/2` copies `deps`
    # and `_build/<env>/lib` into every worktree as real directories, which
    # should already match a target repo's directory-only `/deps/` `/_build/`
    # gitignore patterns. This test guards the belt-and-suspenders fallback
    # (see `@ignored_artifact_paths`) for when that gitignore coverage is
    # missing, or some other untracked `deps`/`_build` entry (e.g. a symlink,
    # from a manually-provisioned worktree, or any other unexpected leftover)
    # shows up at the worktree root — such an entry must not false-trip the
    # commit gate on genuinely-committed work.
    test "ignores leaked deps/_build artifact entries", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/artifacts", "main")
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # An untracked `deps` symlink and an untracked `_build` dir — both
      # should be disregarded regardless of how they got there.
      File.ln_s!(System.tmp_dir!(), Path.join(path, "deps"))
      File.mkdir_p!(Path.join(path, "_build/dev"))
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A genuine untracked source file still counts as dirty.
      File.write!(Path.join(path, "lib_real.ex"), "defmodule X do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(path)
    end

    # Regression for bd-5diu69: per-task worktrees receive a per-run .mcp.json
    # (the MCP runtime config, see bd-2wwuuf). A leaked top-level untracked
    # .mcp.json false-fails the commit gate on committed work. A worktree with
    # commits ahead of base + ONLY an untracked .mcp.json must read as clean.
    test "ignores leaked .mcp.json artifact entry", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/mcp-json", "main")

      # Make a commit to be ahead of base (matches the real scenario).
      File.write!(Path.join(path, "work.ex"), "defmodule Work do end\n")
      {_, 0} = System.cmd("git", ["-C", path, "add", "work.ex"])
      {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "add work"])

      # Worktree is clean before adding artifacts.
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # Leaked .mcp.json should be disregarded.
      File.write!(Path.join(path, ".mcp.json"), "{}")
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A genuine untracked source file still counts as dirty.
      File.write!(Path.join(path, "lib_real.ex"), "defmodule X do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(path)
    end

    # Regression for bd-3gpeoz: `mix test` can compile `.beam` files into the
    # worktree root (e.g. `Elixir.Arbiter.Worker.Worktree.beam`). These are
    # build artifacts and are covered by `*.beam` in `.gitignore`. A worktree
    # with committed work + ONLY a gitignored `.beam` artifact must read as clean.
    test "ignores gitignored .beam build artifacts at the worktree root", %{repo: repo} do
      # Add *.beam to .gitignore in the source repo and commit it (mirrors the
      # real repo where `.gitignore` includes `*.beam`).
      File.write!(Path.join(repo, ".gitignore"), "*.beam\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", ".gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add *.beam to gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      {:ok, path} = Worktree.create(repo, "feature/beam-artifact", "main")

      # Make a commit to be ahead of base (matches the real scenario where the
      # worker pushed their implementation and then mix test compiled artifacts).
      File.write!(Path.join(path, "work.ex"), "defmodule Work do end\n")
      {_, 0} = System.cmd("git", ["-C", path, "add", "work.ex"])
      {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "add work"])

      # Worktree is clean before adding artifacts.
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A leaked .beam file (as produced by `mix test`) must be disregarded
      # because it is covered by `*.beam` in `.gitignore`.
      File.write!(Path.join(path, "Elixir.Arbiter.Worker.Worktree.beam"), <<>>)
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A genuine untracked source file still counts as dirty.
      File.write!(Path.join(path, "lib_real.ex"), "defmodule X do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(path)
    end

    # Regression for bd-arywbh: `.run-server.sh` is generated by `arb
    # install-service` as a dev-mode launcher script (bd-1vhgn7) and must be
    # gitignored so it doesn't false-trip the commit gate on unrelated work.
    test "ignores gitignored .run-server.sh generated script", %{repo: repo} do
      # Add .run-server.sh to .gitignore in the source repo and commit it.
      File.write!(Path.join(repo, ".gitignore"), ".run-server.sh\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", ".gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "gitignore .run-server.sh"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      {:ok, path} = Worktree.create(repo, "feature/run-server-script", "main")

      # Make a commit to be ahead of base (matches the real scenario).
      File.write!(Path.join(path, "work.ex"), "defmodule Work do end\n")
      {_, 0} = System.cmd("git", ["-C", path, "add", "work.ex"])
      {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "add work"])

      # Worktree is clean before adding artifacts.
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      # A leaked .run-server.sh file (generated by arb install-service) must
      # be disregarded because it is covered by `.run-server.sh` in `.gitignore`.
      File.write!(Path.join(path, ".run-server.sh"), "#!/bin/sh\necho hi\n")
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

  describe "rebase_onto_origin/2" do
    test "rebases local-only commits onto a diverged remote tip, preserving both sides (bd-3doy0y)",
         %{repo: repo, remote: remote, root: root} do
      {:ok, path} = Worktree.create(repo, "feature/rebase-diverge", "main")

      # ReviewGate implementer round: pushes a fix commit straight to
      # origin/<branch> from a separate clone, without touching this
      # worktree's local ref.
      advance_origin_branch!(
        root,
        remote,
        "feature/rebase-diverge",
        "implementer.txt",
        "implementer work\n"
      )

      # Meanwhile the main worker's own worktree makes its own local commit —
      # now genuinely diverged from origin, not merely behind.
      :ok = commit(path, "main-worker.txt", "main worker work\n", "main worker fix")

      assert {:ok, :rebased} = Worktree.rebase_onto_origin(path, "feature/rebase-diverge")

      assert File.exists?(Path.join(path, "implementer.txt"))
      assert File.exists?(Path.join(path, "main-worker.txt"))

      # Local is now strictly ahead of origin/<branch> — a normal (non-force)
      # push must succeed.
      assert {:ok, _} = Worktree.push(path, branch: "feature/rebase-diverge")

      {out, 0} =
        System.cmd("git", ["-C", remote, "show", "feature/rebase-diverge:implementer.txt"])

      assert out == "implementer work\n"

      {out2, 0} =
        System.cmd("git", ["-C", remote, "show", "feature/rebase-diverge:main-worker.txt"])

      assert out2 == "main worker work\n"
    end

    test "fast-forwards (no rebase needed) when local is merely behind", %{
      repo: repo,
      remote: remote,
      root: root
    } do
      {:ok, path} = Worktree.create(repo, "feature/rebase-ff", "main")

      advance_origin_branch!(
        root,
        remote,
        "feature/rebase-ff",
        "implementer.txt",
        "implementer work\n"
      )

      assert {:ok, :synced} = Worktree.rebase_onto_origin(path, "feature/rebase-ff")
      assert File.exists?(Path.join(path, "implementer.txt"))
    end

    test "is a no-op when local already matches origin", %{repo: repo} do
      {:ok, path} = Worktree.create(repo, "feature/rebase-noop", "main")

      {_, 0} =
        System.cmd("git", ["-C", path, "push", "-q", "-u", "origin", "feature/rebase-noop"])

      assert {:ok, :up_to_date} = Worktree.rebase_onto_origin(path, "feature/rebase-noop")
    end

    test "aborts and reports the conflict distinctly, leaving the worktree clean on its own commit",
         %{repo: repo, remote: remote, root: root} do
      {:ok, path} = Worktree.create(repo, "feature/rebase-conflict", "main")

      advance_origin_branch!(
        root,
        remote,
        "feature/rebase-conflict",
        "README.md",
        "implementer changed this line\n"
      )

      :ok =
        commit(
          path,
          "README.md",
          "main worker changed this line differently\n",
          "main worker edits README"
        )

      assert {:error, {:diverged_conflict, %{files: files}}} =
               Worktree.rebase_onto_origin(path, "feature/rebase-conflict")

      assert "README.md" in files

      # Left clean on the worker's own commit — never half-rebased.
      assert {:ok, false} = Worktree.has_uncommitted?(path)

      {out, 0} =
        System.cmd("git", ["-C", path, "log", "-1", "--format=%s"], stderr_to_stdout: true)

      assert String.trim(out) == "main worker edits README"
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

  describe "seed_compiled_deps/2" do
    test "copies dep dirs from source _build/test/lib into the worktree", %{
      repo: repo
    } do
      {:ok, wt} = Worktree.create(repo, "feature/seed-basic", "main")

      # Plant a fake compiled dep in the source repo.
      dep_src = Path.join([repo, "_build", "test", "lib", "jason"])
      ebin_src = Path.join(dep_src, "ebin")
      File.mkdir_p!(ebin_src)
      File.write!(Path.join(ebin_src, "jason.beam"), "fake beam")
      File.mkdir_p!(Path.join([repo, "deps", "jason"]))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      dep_dst = Path.join([wt, "_build", "test", "lib", "jason"])
      ebin_dst = Path.join(dep_dst, "ebin")
      assert File.dir?(dep_dst)
      assert File.exists?(Path.join(ebin_dst, "jason.beam"))
    end

    test "excludes app dirs (arbiter, arbiter_web, arbiter_cli) from the copy", %{
      repo: repo
    } do
      {:ok, wt} = Worktree.create(repo, "feature/seed-exclude", "main")

      # Arbiter's own umbrella apps: compiled under _build/.../lib but never
      # fetched, so no matching deps/<app> entry exists.
      for app <- ~w(arbiter arbiter_web arbiter_cli) do
        dir = Path.join([repo, "_build", "test", "lib", app])
        File.mkdir_p!(dir)
      end

      # A real fetched dependency has both _build/.../lib/<dep> AND deps/<dep>.
      dep_dir = Path.join([repo, "_build", "test", "lib", "plug"])
      File.mkdir_p!(dep_dir)
      File.mkdir_p!(Path.join([repo, "deps", "plug"]))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      lib = Path.join([wt, "_build", "test", "lib"])
      assert File.dir?(Path.join(lib, "plug")), "dep 'plug' should be copied"

      for app <- ~w(arbiter arbiter_web arbiter_cli) do
        refute File.exists?(Path.join(lib, app)), "app dir '#{app}' must NOT be copied"
      end
    end

    test "excludes the TARGET repo's own compiled app dir even when its name isn't in Arbiter's umbrella (bd-iz7483)",
         %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-exclude-other-repo", "main")

      # Simulate a non-Arbiter managed repo (e.g. vstim): its own compiled
      # app dir has no matching deps/<name> entry, unlike a real dependency.
      own_app_dir = Path.join([repo, "_build", "test", "lib", "vstim"])
      File.mkdir_p!(own_app_dir)

      real_dep_dir = Path.join([repo, "_build", "test", "lib", "phoenix"])
      File.mkdir_p!(real_dep_dir)
      File.mkdir_p!(Path.join([repo, "deps", "phoenix"]))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      lib = Path.join([wt, "_build", "test", "lib"])
      assert File.dir?(Path.join(lib, "phoenix")), "real dep 'phoenix' should be copied"

      refute File.exists?(Path.join(lib, "vstim")),
             "target repo's own app dir 'vstim' must NOT be copied even though it's not in Arbiter's hardcoded app list"
    end

    test "seeds both test and dev envs when both exist in source", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-envs", "main")

      for env <- ~w(test dev) do
        File.mkdir_p!(Path.join([repo, "_build", env, "lib", "ecto"]))
      end

      File.mkdir_p!(Path.join([repo, "deps", "ecto"]))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      assert File.dir?(Path.join([wt, "_build", "test", "lib", "ecto"]))
      assert File.dir?(Path.join([wt, "_build", "dev", "lib", "ecto"]))
    end

    test "is a no-op when the source repo has no _build dir", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-no-build", "main")

      refute File.dir?(Path.join(repo, "_build"))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      refute File.dir?(Path.join(wt, "_build"))
    end

    test "skips a dep that is already present in the worktree", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-skip-existing", "main")

      ebin_src = Path.join([repo, "_build", "test", "lib", "telemetry", "ebin"])
      File.mkdir_p!(ebin_src)
      File.write!(Path.join(ebin_src, "telemetry.beam"), "source version")
      File.mkdir_p!(Path.join([repo, "deps", "telemetry"]))

      ebin_dst = Path.join([wt, "_build", "test", "lib", "telemetry", "ebin"])
      File.mkdir_p!(ebin_dst)
      File.write!(Path.join(ebin_dst, "telemetry.beam"), "pre-existing version")

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      # The pre-existing version in the worktree must not be overwritten.
      assert File.read!(Path.join(ebin_dst, "telemetry.beam")) == "pre-existing version"
    end

    test "create/3 seeds compiled deps from the source repo into the fresh worktree", %{
      repo: repo
    } do
      dep_src = Path.join([repo, "_build", "test", "lib", "phoenix"])
      File.mkdir_p!(dep_src)
      File.write!(Path.join(dep_src, "phoenix.app"), "[{application, phoenix}].")
      File.mkdir_p!(Path.join([repo, "deps", "phoenix"]))

      assert {:ok, wt} = Worktree.create(repo, "feature/seed-on-create", "main")

      dep_dst = Path.join([wt, "_build", "test", "lib", "phoenix"])
      assert File.dir?(dep_dst), "compiled deps must be seeded by create/3"
      assert File.exists?(Path.join(dep_dst, "phoenix.app"))

      # App dirs must not be present.
      for app <- ~w(arbiter arbiter_web arbiter_cli) do
        refute File.exists?(Path.join([wt, "_build", "test", "lib", app]))
      end
    end

    # bd-6040y1: seed_compiled_deps only copied _build/, never deps/ itself —
    # so `mix test` in a fresh worktree still saw every dep as "not available"
    # and workers had to run a real `mix deps.get` against Hex on every dispatch.
    test "copies the deps/ directory itself, not just _build/", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-deps-dir", "main")

      dep_src = Path.join([repo, "deps", "jason"])
      File.mkdir_p!(Path.join(dep_src, "lib"))
      File.write!(Path.join([dep_src, "lib", "jason.ex"]), "defmodule Jason do end\n")
      File.write!(Path.join(dep_src, "mix.exs"), "# jason mix.exs\n")

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      dep_dst = Path.join([wt, "deps", "jason"])
      assert File.dir?(dep_dst)

      {:ok, %File.Stat{type: type}} = File.lstat(dep_dst)
      assert type == :directory, "deps/<dep> must be a real copy, not a symlink"
      assert File.exists?(Path.join([dep_dst, "lib", "jason.ex"]))
      assert File.exists?(Path.join(dep_dst, "mix.exs"))
    end

    test "deps/ copy is a no-op when the source repo has no deps dir", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-deps-no-src", "main")

      refute File.dir?(Path.join(repo, "deps"))

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      refute File.dir?(Path.join(wt, "deps"))
    end

    test "skips a deps/<dep> entry that is already present in the worktree", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/seed-deps-skip-existing", "main")

      File.mkdir_p!(Path.join([repo, "deps", "telemetry"]))
      File.write!(Path.join([repo, "deps", "telemetry", "mix.exs"]), "source version")

      dest_dep = Path.join([wt, "deps", "telemetry"])
      File.mkdir_p!(dest_dep)
      File.write!(Path.join(dest_dep, "mix.exs"), "pre-existing version")

      assert :ok = Worktree.seed_compiled_deps(repo, wt)

      # The pre-existing version in the worktree must not be overwritten.
      assert File.read!(Path.join(dest_dep, "mix.exs")) == "pre-existing version"
    end

    test "create/3 seeds the deps/ directory into the fresh worktree", %{repo: repo} do
      File.mkdir_p!(Path.join([repo, "deps", "phoenix"]))
      File.write!(Path.join([repo, "deps", "phoenix", "mix.exs"]), "phoenix mix.exs")

      assert {:ok, wt} = Worktree.create(repo, "feature/seed-deps-on-create", "main")

      dep_dst = Path.join([wt, "deps", "phoenix"])
      assert File.dir?(dep_dst), "deps/<dep> must be seeded by create/3"
      assert File.exists?(Path.join(dep_dst, "mix.exs"))
    end
  end

  defp rev_parse(path, ref) do
    {out, 0} = System.cmd("git", ["-C", path, "rev-parse", ref], stderr_to_stdout: true)
    String.trim(out)
  end

  defp head_sha(path), do: rev_parse(path, "HEAD")

  # Push a commit to the bare `remote` from a throwaway clone, so the source
  # checkout's own refs stay behind — the "human hasn't pulled in a month" shape
  # bd-9r1tta is about.
  defp advance_origin!(tmp, remote, file, content) do
    clone = Path.join(tmp, "advance-#{:erlang.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(clone, file), content)
    {_, 0} = System.cmd("git", ["-C", clone, "add", file])
    {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance origin"])
    {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])
    :ok
  end

  # Like advance_origin!/4 but for an arbitrary branch — pushes a commit to
  # `origin/<branch>` from a throwaway clone (checking the branch out first
  # if the clone doesn't already have it locally), simulating a second
  # writer (e.g. the ReviewGate implementer round) pushing directly to the
  # remote without the caller's worktree ever seeing it.
  defp advance_origin_branch!(tmp, remote, branch, file, content) do
    clone = Path.join(tmp, "advance-#{:erlang.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])

    case System.cmd("git", ["-C", clone, "checkout", "-q", branch], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> {_, 0} = System.cmd("git", ["-C", clone, "checkout", "-q", "-b", branch])
    end

    File.write!(Path.join(clone, file), content)
    {_, 0} = System.cmd("git", ["-C", clone, "add", file])
    {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance " <> branch])
    {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", branch])
    :ok
  end

  # Commit `content` to `file` in `path` and return :ok.
  defp commit(path, file, content, msg) do
    File.write!(Path.join(path, file), content)
    {_, 0} = System.cmd("git", ["-C", path, "add", file], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", msg], stderr_to_stdout: true)
    :ok
  end

  # Advance origin/main with a commit to `file` (made in `repo`, pushed).
  defp advance_origin_main(repo, file, content, msg) do
    :ok = commit(repo, file, content, msg)

    {_, 0} =
      System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"], stderr_to_stdout: true)

    :ok
  end

  defp changed_files(path, range) do
    {out, 0} =
      System.cmd("git", ["-C", path, "diff", "--name-only", range], stderr_to_stdout: true)

    out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
  end

  # bd-ased52: bring the branch current with its (possibly advanced) target
  # before review, and isolate the branch's own changes via the merge-base.
  describe "update_from_target/2 + merge_base/2" do
    test "no-op when the target has not advanced", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/upd-noop", "main")
      :ok = commit(wt, "a.txt", "branch work\n", "branch a")

      assert {:ok, :up_to_date} = Worktree.update_from_target(wt, "main")
      assert {:ok, false} = Worktree.has_uncommitted?(wt)
    end

    test "merges an advanced target and the change set EXCLUDES the target's unrelated file",
         %{repo: repo} do
      # Branch cut from the OLD main; only touches a.txt.
      {:ok, wt} = Worktree.create(repo, "feature/upd-merge", "main")
      :ok = commit(wt, "a.txt", "branch work\n", "branch a")

      # The target advances mid-run with an UNRELATED file (b.txt).
      :ok = advance_origin_main(repo, "b.txt", "fleet work\n", "main b")

      assert {:ok, :merged} = Worktree.update_from_target(wt, "main")
      assert {:ok, false} = Worktree.has_uncommitted?(wt)
      assert {:ok, "feature/upd-merge"} = Worktree.current_branch(wt)

      base = Worktree.merge_base(wt, "main")
      assert is_binary(base)

      files = changed_files(wt, "#{base}..HEAD")

      assert "a.txt" in files,
             "the branch's own change must be in the merge-base diff"

      refute "b.txt" in files,
             "the target's unrelated commit must NOT appear in the branch's change set"
    end

    test "a conflicting target advance returns {:error, {:conflict, _}} and leaves a clean tree",
         %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/upd-conflict", "main")
      # The branch edits README.md (a file that exists on main)...
      :ok = commit(wt, "README.md", "branch version\n", "branch readme")
      # ...and the target advances editing the SAME file differently.
      :ok = advance_origin_main(repo, "README.md", "fleet version\n", "main readme")

      assert {:error, {:conflict, %{files: files}}} = Worktree.update_from_target(wt, "main")
      assert "README.md" in files

      # The merge was aborted: the worktree is clean and still on its branch.
      assert {:ok, false} = Worktree.has_uncommitted?(wt)
      assert {:ok, "feature/upd-conflict"} = Worktree.current_branch(wt)
    end

    test "merge_base/2 resolves the fork point of an un-updated branch", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/mb", "main")
      :ok = commit(wt, "a.txt", "branch work\n", "branch a")
      :ok = advance_origin_main(repo, "b.txt", "fleet work\n", "main b")

      # Without updating, the merge-base is still the original fork point, so a
      # base..HEAD diff already excludes the target's later commit.
      base = Worktree.merge_base(wt, "main")
      assert is_binary(base)
      files = changed_files(wt, "#{base}..HEAD")
      assert "a.txt" in files
      refute "b.txt" in files
    end
  end

  # bd-9q966y: belt-and-suspenders commit gate check for injected agent-config files.
  describe "has_injected_config_in_commits?/2" do
    test "returns false when no injected config files are in the diff", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/no-secret", "main")
      :ok = commit(wt, "ok.ex", "defmodule X do end\n", "add module")

      assert {:ok, false} = Worktree.has_injected_config_in_commits?(wt, "main")
    end

    test "returns true when .mcp.json is in the committed diff", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/secret-mcp", "main")
      :ok = commit(wt, "ok.ex", "defmodule OK do end\n", "add module")
      # Explicitly stage and commit .mcp.json (bypassing .git/info/exclude)
      :ok = commit(wt, ".mcp.json", ~s({"secret": "tok"}), "oops: commit token file")

      assert {:ok, true} = Worktree.has_injected_config_in_commits?(wt, "main")
    end

    test "returns true when a .gemini/ file is in the committed diff", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/secret-gemini", "main")
      File.mkdir_p!(Path.join(wt, ".gemini"))
      :ok = commit(wt, ".gemini/settings.json", ~s({"token": "x"}), "oops: gemini config")

      assert {:ok, true} = Worktree.has_injected_config_in_commits?(wt, "main")
    end

    test "returns true when a .codex/ file is in the committed diff", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/secret-codex", "main")
      File.mkdir_p!(Path.join(wt, ".codex"))
      :ok = commit(wt, ".codex/config.toml", ~s([mcp]\ntoken = "x"), "oops: codex config")

      assert {:ok, true} = Worktree.has_injected_config_in_commits?(wt, "main")
    end

    test "fails open (false) when the git diff cannot be run", %{repo: repo} do
      assert {:ok, false} =
               Worktree.has_injected_config_in_commits?("/nonexistent/path/xyz", "main")

      # Also fails open when base_ref doesn't exist
      {:ok, wt} = Worktree.create(repo, "feature/no-base-ref", "main")
      :ok = commit(wt, "ok.ex", "x\n", "initial")
      assert {:ok, false} = Worktree.has_injected_config_in_commits?(wt, "nonexistent-branch")
    end

    # bd-4ltc3e: a two-dot `base..HEAD` diff picks up files that changed on
    # `base` after the branch was cut, even though the branch itself never
    # touched them. If `base` (e.g. `development`) later gains a commit that
    # (accidentally) added .mcp.json, EVERY branch forked before that commit
    # false-trips this gate on its own clean, unrelated work — exactly the
    # bd-9q966y leak commit manifesting as a false positive elsewhere.
    test "does not false-trip when the target branch (not the feature branch) carries the injected file",
         %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/target-carries-secret", "main")
      :ok = commit(wt, "ok.ex", "defmodule OK do end\n", "legit unrelated change")

      # main advances AFTER the fork point with a commit that leaks .mcp.json.
      :ok = advance_origin_main(repo, ".mcp.json", ~s({"secret": "tok"}), "oops: leaked on main")

      assert {:ok, false} = Worktree.has_injected_config_in_commits?(wt, "main")
    end

    # bd-bhrji9: regression — `.arbiter/INBOX` (written by
    # Arbiter.Messages.WorktreeDelivery, predates bd-9q966y by ~9 days) was never
    # added to this pattern list, so a worker committing it slipped straight past
    # the commit gate and was only caught by a downstream ReviewGate round.
    test "returns true when .arbiter/INBOX is in the committed diff (force-added, bypassing exclude)",
         %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/secret-arbiter-inbox", "main")
      File.mkdir_p!(Path.join(wt, ".arbiter"))
      File.write!(Path.join(wt, ".arbiter/INBOX"), "[2026-07-27] some direction\n---\n")
      # `Worktree.create/3` now excludes `.arbiter/` on its own (bd-bhrji9), so a
      # plain `git add` refuses an ignored path — force it, simulating the "add
      # flags bypassed the exclude" case the commit gate exists to backstop.
      {_, 0} = System.cmd("git", ["-C", wt, "add", "-f", ".arbiter/INBOX"])
      {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "oops: inbox file"])

      assert {:ok, true} = Worktree.has_injected_config_in_commits?(wt, "main")
    end
  end

  describe "create/3 excludes .arbiter/ (bd-bhrji9)" do
    test "adds .arbiter/ to the repo's (common-dir) info/exclude on creation", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/arbiter-excl", "main")

      {common_dir, 0} = System.cmd("git", ["-C", wt, "rev-parse", "--git-common-dir"])
      exclude_path = Path.join([String.trim(common_dir), "info", "exclude"])
      exclude_content = File.read!(exclude_path)
      assert exclude_content =~ ".arbiter/"
    end

    test "git add -A does NOT stage .arbiter/INBOX after creation", %{repo: repo} do
      {:ok, wt} = Worktree.create(repo, "feature/arbiter-excl-add", "main")

      File.mkdir_p!(Path.join(wt, ".arbiter"))
      File.write!(Path.join(wt, ".arbiter/INBOX"), "[2026-07-27] direction\n---\n")

      {_, 0} = System.cmd("git", ["-C", wt, "add", "-A"])

      {status_out, 0} =
        System.cmd("git", ["-C", wt, "status", "--porcelain"], stderr_to_stdout: true)

      refute status_out =~ ".arbiter",
             "expected .arbiter/ to be excluded from git staging, got:\n#{status_out}"
    end
  end

  # bd-bhrji9: reproduces the exact failure conditions from the incident —
  # a contributor repo with NO tracked .gitignore for either injected path,
  # a worktree provisioned via the real Worktree.create/3 + AgentConfig.write/3
  # + WorktreeDelivery.write_inbox/3 paths (not hand-rolled fixtures), and a
  # worker committing with a blunt `git add -A && git commit`. Neither
  # `.mcp.json` nor `.arbiter/INBOX` may end up in the resulting commit.
  describe "end-to-end regression (bd-bhrji9): worker git add -A must never sweep injected files" do
    test "no .gitignore in the repo, git add -A + commit -> neither .mcp.json nor .arbiter/ land in the commit",
         %{repo: repo} do
      refute File.exists?(Path.join(repo, ".gitignore"))

      {:ok, wt} = Worktree.create(repo, "feature/e2e-no-gitignore", "main")

      # Same two injection points a live dispatch exercises: the per-spawn MCP
      # config (Arbiter.MCP.AgentConfig.write/3) and the Admiral/coordinator
      # mailbox delivery (Arbiter.Messages.WorktreeDelivery.write_inbox/3, via
      # its private write_inbox — exercised directly here since it needs a
      # running worker registry to resolve worktree_path).
      assert :ok =
               Arbiter.MCP.AgentConfig.write(:claude, wt,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-e2e-regression"
               )

      File.mkdir_p!(Path.join(wt, ".arbiter"))
      File.write!(Path.join(wt, ".arbiter/INBOX"), "[2026-07-27T00:00:00Z]\ndirection\n---\n")

      # The worker's own source-code contribution.
      File.write!(Path.join(wt, "app.ex"), "defmodule App do end\n")

      {_, 0} = System.cmd("git", ["-C", wt, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", wt, "config", "user.email", "worker@example.com"])
      {_, 0} = System.cmd("git", ["-C", wt, "config", "user.name", "Worker"])
      {_, 0} = System.cmd("git", ["-C", wt, "config", "commit.gpgsign", "false"])
      {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "add app"])

      {committed, 0} =
        System.cmd("git", ["-C", wt, "diff", "--name-only", "main..HEAD", "--"])

      refute committed =~ ".mcp.json",
             "expected .mcp.json absent from the commit, got:\n#{committed}"

      refute committed =~ ".arbiter",
             "expected .arbiter/ absent from the commit, got:\n#{committed}"

      assert committed =~ "app.ex"

      assert {:ok, false} = Worktree.has_injected_config_in_commits?(wt, "main")
    end
  end
end
