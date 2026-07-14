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
  end
end
