defmodule Arbiter.Reviews.CheckoutTest do
  use ExUnit.Case, async: true

  alias Arbiter.Reviews.Checkout

  # Builds an "origin" repo with two commits and a "clone" repo (a real local
  # clone with `origin` pointed back at it via a filesystem path) — the head
  # commit exists in `origin` but NOT yet in `clone`, mirroring a PR whose
  # head commit a worker's shared checkout hasn't fetched yet.
  defp origin_and_clone do
    root = Path.join(System.tmp_dir!(), "checkout-test-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin")
    clone = Path.join(root, "clone")
    File.mkdir_p!(origin)

    {_, 0} = System.cmd("git", ["init", "-q", origin])
    {_, 0} = System.cmd("git", ["-C", origin, "config", "user.email", "t@t.com"])
    {_, 0} = System.cmd("git", ["-C", origin, "config", "user.name", "t"])
    File.write!(Path.join(origin, "a.txt"), "a")
    {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "init"])

    {_, 0} = System.cmd("git", ["clone", "-q", origin, clone])
    {_, 0} = System.cmd("git", ["-C", clone, "remote", "set-url", "origin", origin])

    File.write!(Path.join(origin, "b.txt"), "b")
    {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "second"])
    {head_sha, 0} = System.cmd("git", ["-C", origin, "rev-parse", "HEAD"])
    head_sha = String.trim(head_sha)

    on_exit(fn -> File.rm_rf(root) end)

    {clone, head_sha}
  end

  describe "provision/2" do
    test "fetches the PR head commit and checks it out into a throwaway worktree" do
      {clone, head_sha} = origin_and_clone()

      assert {:ok, path} = Checkout.provision(clone, head_sha)
      assert File.dir?(path)
      assert File.exists?(Path.join(path, "b.txt"))

      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
      assert String.trim(out) == head_sha

      Checkout.teardown(path)
    end

    test "returns an error (never raises) when repo_path is nil" do
      assert {:error, :no_repo_path} = Checkout.provision(nil, "deadbeef")
    end

    test "returns an error (never raises) when head_sha is nil" do
      {clone, _head_sha} = origin_and_clone()
      assert {:error, :no_head_sha} = Checkout.provision(clone, nil)
    end

    test "returns an error when the repo_path isn't a git repo at all" do
      not_a_repo =
        Path.join(System.tmp_dir!(), "not-a-repo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      assert {:error, _reason} = Checkout.provision(not_a_repo, "deadbeef")
    end

    test "returns an error when the commit doesn't exist anywhere reachable" do
      {clone, _head_sha} = origin_and_clone()

      assert {:error, _reason} =
               Checkout.provision(clone, "0000000000000000000000000000000000000000")
    end
  end

  # Same shape as `origin_and_clone/0`, but the second commit lands on a NAMED
  # branch in `origin` that the clone has never fetched — the internal
  # reviewer's case (bd-199giy): a task branch pushed by the implementer whose
  # head the coordinator's shared checkout has not seen.
  defp origin_and_clone_with_branch(branch) do
    root = Path.join(System.tmp_dir!(), "checkout-branch-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin")
    clone = Path.join(root, "clone")
    File.mkdir_p!(origin)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", origin])
    {_, 0} = System.cmd("git", ["-C", origin, "config", "user.email", "t@t.com"])
    {_, 0} = System.cmd("git", ["-C", origin, "config", "user.name", "t"])
    {_, 0} = System.cmd("git", ["-C", origin, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(origin, "a.txt"), "a")
    {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "init"])

    {_, 0} = System.cmd("git", ["clone", "-q", origin, clone])
    {_, 0} = System.cmd("git", ["-C", clone, "remote", "set-url", "origin", origin])

    {_, 0} = System.cmd("git", ["-C", origin, "checkout", "-q", "-b", branch])
    File.write!(Path.join(origin, "b.txt"), "b")
    {_, 0} = System.cmd("git", ["-C", origin, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", origin, "commit", "-q", "-m", "branch work"])
    {head_sha, 0} = System.cmd("git", ["-C", origin, "rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(root) end)

    {clone, String.trim(head_sha)}
  end

  describe "provision/3 opts" do
    test ":prefix names the throwaway worktree leaf" do
      {clone, head_sha} = origin_and_clone()

      assert {:ok, path} = Checkout.provision(clone, head_sha, prefix: "review")
      assert Path.basename(path) =~ ~r/^review-/

      Checkout.teardown(path)
    end

    test "defaults the leaf prefix to ext-review" do
      {clone, head_sha} = origin_and_clone()

      assert {:ok, path} = Checkout.provision(clone, head_sha)
      assert Path.basename(path) =~ ~r/^ext-review-/

      Checkout.teardown(path)
    end
  end

  describe "provision_branch/3" do
    test "fetches the branch's current head and checks it out detached" do
      branch = "feature/bd-199giy-under-review"
      {clone, head_sha} = origin_and_clone_with_branch(branch)

      assert {:ok, %{path: path, head_sha: ^head_sha}} =
               Checkout.provision_branch(clone, branch)

      assert File.dir?(path)
      assert File.exists?(Path.join(path, "b.txt"))

      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
      assert String.trim(out) == head_sha

      # Detached: no branch is checked out, so the same branch stays available
      # to the implementer's own worktree.
      {sym, code} =
        System.cmd("git", ["-C", path, "symbolic-ref", "-q", "HEAD"], stderr_to_stdout: true)

      assert code != 0
      assert String.trim(sym) == ""

      Checkout.teardown(path)
    end

    test "honors the :prefix opt" do
      branch = "feature/bd-199giy-prefixed"
      {clone, _head_sha} = origin_and_clone_with_branch(branch)

      assert {:ok, %{path: path}} = Checkout.provision_branch(clone, branch, prefix: "review")
      assert Path.basename(path) =~ ~r/^review-/

      Checkout.teardown(path)
    end

    test "returns an error (never raises) when repo_path is missing" do
      assert {:error, :no_repo_path} = Checkout.provision_branch(nil, "feature/x")
      assert {:error, :no_repo_path} = Checkout.provision_branch("", "feature/x")
    end

    test "returns an error (never raises) when the branch is missing" do
      {clone, _head_sha} = origin_and_clone()

      assert {:error, :no_branch} = Checkout.provision_branch(clone, nil)
      assert {:error, :no_branch} = Checkout.provision_branch(clone, "")
    end

    test "falls back to a local-only branch when origin has never seen it" do
      {clone, _head_sha} = origin_and_clone()

      # A branch that exists ONLY in the local checkout — the Direct
      # (local-merge) strategy's shape, where nothing is ever pushed.
      {_, 0} = System.cmd("git", ["-C", clone, "checkout", "-q", "-b", "feature/local-only"])
      File.write!(Path.join(clone, "local.txt"), "local")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "-A"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          clone,
          "-c",
          "user.email=t@t.com",
          "-c",
          "user.name=t",
          "commit",
          "-q",
          "-m",
          "local work"
        ])

      {local_sha, 0} = System.cmd("git", ["-C", clone, "rev-parse", "HEAD"])
      local_sha = String.trim(local_sha)
      {_, 0} = System.cmd("git", ["-C", clone, "checkout", "-q", "-"])

      assert {:ok, %{path: path, head_sha: ^local_sha}} =
               Checkout.provision_branch(clone, "feature/local-only")

      assert File.exists?(Path.join(path, "local.txt"))

      Checkout.teardown(path)
    end

    test "prefers origin's tip over a stale local branch of the same name" do
      branch = "feature/bd-199giy-stale-local"
      {clone, origin_sha} = origin_and_clone_with_branch(branch)

      # Fetch it once, then let the local ref fall behind by a commit that
      # never reaches origin — the shared checkout going stale.
      {_, 0} = System.cmd("git", ["-C", clone, "fetch", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", clone, "branch", "-q", branch, "HEAD"])

      {local_sha, 0} = System.cmd("git", ["-C", clone, "rev-parse", branch])
      refute String.trim(local_sha) == origin_sha

      assert {:ok, %{path: path, head_sha: ^origin_sha}} =
               Checkout.provision_branch(clone, branch)

      Checkout.teardown(path)
    end

    test "returns an error when the branch exists neither on origin nor locally" do
      {clone, _head_sha} = origin_and_clone()

      assert {:error, _reason} = Checkout.provision_branch(clone, "feature/never-pushed")
    end

    test "returns an error when repo_path isn't a git repo at all" do
      not_a_repo =
        Path.join(System.tmp_dir!(), "not-a-repo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(not_a_repo)
      on_exit(fn -> File.rm_rf(not_a_repo) end)

      assert {:error, _reason} = Checkout.provision_branch(not_a_repo, "feature/x")
    end

    test "leaves no temp fetch refs behind" do
      branch = "feature/bd-199giy-temp-ref"
      {clone, _head_sha} = origin_and_clone_with_branch(branch)

      assert {:ok, %{path: path}} = Checkout.provision_branch(clone, branch)

      {refs, 0} =
        System.cmd("git", ["-C", clone, "for-each-ref", "--format=%(refname)", "refs/arbiter/"])

      assert String.trim(refs) == ""

      Checkout.teardown(path)
    end

    test "resolves the branch's own tip even while other fetches run concurrently" do
      # bd-199giy review: resolving the fetched tip through the shared
      # `.git/FETCH_HEAD` raced every other fetch against the same repo (every
      # dispatch runs `Worktree.fetch_origin/2`), and could silently provision a
      # worktree at *another* branch's tip. The fetch now lands in a private
      # per-call ref, so a competing fetch of `main` cannot be mistaken for the
      # branch under review.
      branch = "feature/bd-199giy-concurrent"
      {clone, head_sha} = origin_and_clone_with_branch(branch)

      {main_sha, 0} = System.cmd("git", ["-C", clone, "rev-parse", "refs/remotes/origin/main"])
      refute String.trim(main_sha) == head_sha

      noise = Task.async(fn -> fetch_noise(clone) end)

      paths =
        for _ <- 1..5 do
          assert {:ok, %{path: path, head_sha: ^head_sha}} =
                   Checkout.provision_branch(clone, branch)

          path
        end

      send(noise.pid, :stop)
      Task.shutdown(noise, :brutal_kill)

      Enum.each(paths, &Checkout.teardown/1)
    end
  end

  # Hammer the shared repo's `.git/FETCH_HEAD` from another process until told
  # to stop, so any FETCH_HEAD-based resolution has a real window to lose.
  defp fetch_noise(clone) do
    receive do
      :stop -> :ok
    after
      0 ->
        System.cmd("git", ["-C", clone, "fetch", "--no-tags", "origin", "main"],
          stderr_to_stdout: true
        )

        fetch_noise(clone)
    end
  end

  describe "teardown/1" do
    test "removes the worktree directory" do
      {clone, head_sha} = origin_and_clone()
      {:ok, path} = Checkout.provision(clone, head_sha)
      assert File.dir?(path)

      assert :ok = Checkout.teardown(path)
      refute File.dir?(path)
    end

    test "is a no-op (never raises) for a path that was never provisioned" do
      assert :ok = Checkout.teardown("/tmp/does-not-exist-#{System.unique_integer([:positive])}")
    end

    test "is a no-op for nil" do
      assert :ok = Checkout.teardown(nil)
    end
  end
end
