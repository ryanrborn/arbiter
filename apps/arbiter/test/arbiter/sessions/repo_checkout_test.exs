defmodule Arbiter.Sessions.RepoCheckoutTest do
  @moduledoc """
  bd-1lszsc acceptance 4: the read-only repo checkout a refine session greps
  for grounding.

  A detached `git worktree` under the session root, with every write bit
  stripped, torn down when the session ends — and never, under any argument,
  the live primary checkout the Arbiter server runs from.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.RepoCheckout
  alias Arbiter.Sessions.Session
  alias Arbiter.Test.SessionEnv

  setup do
    env = SessionEnv.sandbox("repo-checkout")
    {:ok, repo: seed_repo!(), checkout: env[:primary_checkout]}
  end

  # A real git repo with one commit on `main` and a second on a side branch,
  # so "the tip of its default branch" is a claim that can actually be wrong.
  defp seed_repo! do
    dir = Path.join(System.tmp_dir!(), "refine-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git!(dir, ["init", "--initial-branch=main", "--quiet"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "README.md"), "on main\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "--quiet", "-m", "main commit"])

    git!(dir, ["checkout", "--quiet", "-b", "side"])
    File.write!(Path.join(dir, "README.md"), "on side\n")
    git!(dir, ["commit", "--quiet", "-am", "side commit"])
    git!(dir, ["checkout", "--quiet", "main"])

    dir
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp session(id \\ Ash.UUID.generate()) do
    %Session{id: id, cwd: Layout.workspace_dir(id), scope_unit: "x", tmux_socket: "y"}
  end

  describe "provision/3" do
    test "checks the default branch tip out, detached, under the session root", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      assert {:ok, checkout} = RepoCheckout.provision(session, repo, "main")

      assert checkout.path == Layout.repo_checkout_dir(session.id)
      assert File.read!(Path.join(checkout.path, "README.md")) == "on main\n"

      # Detached: nothing the session does can advance a branch in the source
      # repo, because HEAD names no branch at all.
      assert {_out, code} =
               System.cmd("git", ["-C", checkout.path, "symbolic-ref", "-q", "HEAD"],
                 stderr_to_stdout: true
               )

      assert code != 0

      assert checkout.head_sha == String.trim(git!(repo, ["rev-parse", "main"]))
    end

    test "strips every write bit — writes into the checkout fail", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      {:ok, checkout} = RepoCheckout.provision(session, repo, "main")

      assert {:error, :eacces} = File.write(Path.join(checkout.path, "README.md"), "nope")
      assert {:error, :eacces} = File.write(Path.join(checkout.path, "new-file.txt"), "nope")
      assert {:error, :eacces} = File.mkdir(Path.join(checkout.path, "subdir"))
    end

    test "refuses to hand back the live primary checkout", %{repo: repo, checkout: primary} do
      # A repo whose registered path *is* the server's own checkout is exactly
      # the case §10.2 layer 1 exists for: the grounding checkout must be a
      # separate worktree, never the tree Phoenix is hot-reloading.
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      {:ok, checkout} = RepoCheckout.provision(session, repo, "main")
      refute Path.expand(checkout.path) == Path.expand(primary)
      refute Path.expand(checkout.path) == Path.expand(repo)
      assert Layout.outside_primary_checkout?(checkout.path, primary)
    end

    test "a session root inside the primary checkout is refused outright", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      assert {:error, {:inside_primary_checkout, _path, _msg}} =
               RepoCheckout.provision(session, repo, "main", primary_checkout: Layout.root())

      refute File.exists?(Layout.repo_checkout_dir(session.id))
    end

    test "a missing repo path is a named error, not a crash" do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      assert {:error, :no_repo_path} = RepoCheckout.provision(session, nil, "main")
      assert {:error, :no_repo_path} = RepoCheckout.provision(session, "", "main")

      assert {:error, {:rev_parse_failed, _, _}} =
               RepoCheckout.provision(session, Path.join(System.tmp_dir!(), "not-a-repo"), "main")
    end

    test "an unknown branch is a named error", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      assert {:error, {:rev_parse_failed, _, _}} =
               RepoCheckout.provision(session, repo, "no-such-branch")
    end
  end

  describe "teardown/1" do
    test "removes the read-only checkout and deregisters the worktree", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))

      {:ok, checkout} = RepoCheckout.provision(session, repo, "main")
      assert File.dir?(checkout.path)

      assert :ok = RepoCheckout.teardown(session)

      refute File.exists?(checkout.path)
      refute git!(repo, ["worktree", "list"]) =~ checkout.path
    end

    # `File.rm_rf/1` cannot delete a read-only directory tree, so an operator
    # cleanup that ran straight at the session directory would leave the
    # checkout — and everything under it — behind. `Provisioning.destroy/1`
    # has to sweep the checkout first.
    test "the operator's session-directory cleanup can still remove the session", %{repo: repo} do
      session = session()
      File.mkdir_p!(Layout.session_dir(session.id))
      {:ok, _checkout} = RepoCheckout.provision(session, repo, "main")

      assert :ok = Arbiter.Sessions.Provisioning.destroy(session.id)
      refute File.exists?(Layout.session_dir(session.id))
    end

    test "is idempotent and safe for a session that never had one" do
      assert :ok = RepoCheckout.teardown(session())
      assert :ok = RepoCheckout.teardown(session())
    end
  end
end
