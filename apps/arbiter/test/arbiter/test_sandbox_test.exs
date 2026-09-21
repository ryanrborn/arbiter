defmodule Arbiter.TestSandboxTest do
  @moduledoc """
  bd-b6noq9 / #1930 — the provisioning invariants that the four lost
  `/tmp/rev-provider-*` sandboxes violated.

  Those roots were fixture scaffolding: a repo, a bare `origin.git` and a
  `worktrees/` dir, all under one `System.tmp_dir!()` root that the owning
  test's `on_exit` deleted with a single `File.rm_rf!`. Real agent sessions
  were still running inside them, so the delete took the worktree, the origin
  and the only copy of the branch at once, mid-session.

  `Arbiter.TestSandbox` is the provisioning helper that makes that shape
  impossible. The properties asserted here are the acceptance criteria:
  off `/tmp`, origin outside the disposable root, and never deleted while a
  run that owns it is still alive.
  """

  use ExUnit.Case, async: false

  alias Arbiter.TestSandbox

  test "provisions off /tmp, where no external janitor can reach it" do
    sandbox = TestSandbox.provision!("props")

    refute String.starts_with?(sandbox.root, System.tmp_dir!())
    refute String.starts_with?(sandbox.origin, System.tmp_dir!())
    assert String.starts_with?(sandbox.root, Arbiter.Config.Paths.scratch_root())

    TestSandbox.teardown(sandbox)
  end

  test "keeps the bare origin outside the disposable root, so losing the worktree keeps the branch" do
    sandbox = TestSandbox.provision!("origin-split")
    TestSandbox.seed_branch!(sandbox, "feature/keepme")

    # The origin is not inside the root that gets torn down, nor inside the
    # worktree root — the co-location that made #1930 unrecoverable.
    refute String.starts_with?(sandbox.origin, sandbox.root <> "/")
    refute String.starts_with?(sandbox.origin, sandbox.worktree_root <> "/")

    # Lose the entire disposable root, exactly as the incident did.
    File.rm_rf!(sandbox.root)
    refute File.dir?(sandbox.repo)

    # The branch still exists: there is something to re-clone from.
    {out, 0} = System.cmd("git", ["ls-remote", "--heads", sandbox.origin, "feature/keepme"])
    assert out =~ "refs/heads/feature/keepme"

    TestSandbox.teardown(sandbox)
  end

  test "stubs every agent CLI so a spawn can never reach the operator's real binary" do
    sandbox = TestSandbox.provision!("stubs")

    for bin <- TestSandbox.agent_binaries() do
      path = Path.join(sandbox.bin, bin)
      assert File.regular?(path), "#{bin} is not stubbed — a real CLI could be spawned"
      assert System.find_executable(bin) == path
    end

    TestSandbox.teardown(sandbox)
  end

  describe "teardown is gated on the runs that own the sandbox" do
    test "stops owners first, then deletes" do
      sandbox = TestSandbox.provision!("owned")

      {:ok, owner} = Agent.start(fn -> :running end)
      TestSandbox.own!(sandbox, owner)

      TestSandbox.teardown(sandbox)

      refute Process.alive?(owner)
      refute File.exists?(sandbox.root)
    end

    test "refuses to delete a sandbox whose owner is still alive" do
      sandbox = TestSandbox.provision!("stuck-owner")

      # An owner that will not go down on request — stands in for a live agent
      # session mid-rebase. The sandbox holds the only copy of its branch, so
      # deleting it out from under this process is precisely the bug.
      owner =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          receive do: (:never -> :ok)
        end)

      TestSandbox.own!(sandbox, owner)

      assert {:error, {:owners_alive, [^owner]}} = TestSandbox.teardown(sandbox, 50)
      assert File.dir?(sandbox.root)
      assert Process.alive?(owner)

      Process.exit(owner, :kill)
      TestSandbox.teardown(sandbox)
      refute File.exists?(sandbox.root)
    end
  end
end
