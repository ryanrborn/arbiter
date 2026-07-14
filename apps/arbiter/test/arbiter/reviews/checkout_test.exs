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
