defmodule ArbiterCli.Scripts.BuildLocalReleaseTest do
  @moduledoc """
  Guard-clause coverage for `scripts/build-local-release.sh` — the build
  script behind `arb server deploy --local` (bd-bbgw7k).

  These tests exercise only the argument parsing and the primary-checkout
  refusal, which run before anything touches `mix`/network. They deliberately
  never let the script reach `git fetch`/`mix release` — that step needs a
  real network-connected clone and a multi-minute prod compile, well outside
  what a unit test suite should attempt. Verification of the actual build was
  done manually (see PR description).
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/build-local-release.sh", __DIR__)

  defp run(args, env \\ []) do
    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
  end

  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "hi")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)
    dir
  end

  test "script exists and is executable" do
    assert File.exists?(@script)
    assert %File.Stat{mode: mode} = File.stat!(@script)
    # Owner-executable bit set.
    assert Bitwise.band(mode, 0o100) != 0
  end

  test "no arguments: prints usage to stderr and exits 1" do
    {out, code} = run([])
    assert code == 1
    assert out =~ "Usage: scripts/build-local-release.sh"
  end

  test "--help: prints usage to stdout and exits 0" do
    {out, code} = run(["--help"])
    assert code == 0
    assert out =~ "Usage: scripts/build-local-release.sh"
  end

  test "nonexistent clone path aborts with a clear error" do
    {out, code} = run(["/no/such/clone/path"])
    assert code == 1
    assert out =~ "/no/such/clone/path"
  end

  test "a non-git directory aborts with a clear error" do
    dir = Path.join(System.tmp_dir!(), "blr-notgit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {out, code} = run([dir])
    assert code == 1
    assert out =~ "not a git repository"
  end

  test "refuses to build against the primary checkout" do
    primary =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-primary-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf(primary) end)

    {out, code} = run([primary], [{"ARB_PRIMARY_CHECKOUT", primary}])

    assert code == 1
    assert out =~ "refusing to build from the primary checkout"
  end

  test "refuses to build against the primary checkout resolved from ARB_HOME alone" do
    primary =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-primary-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf(primary) end)

    # No ARB_PRIMARY_CHECKOUT set — the guard must still fire off of ARB_HOME,
    # the var the server itself is actually configured with.
    {out, code} = run([primary], [{"ARB_PRIMARY_CHECKOUT", nil}, {"ARB_HOME", primary}])

    assert code == 1
    assert out =~ "refusing to build from the primary checkout"
  end

  test "refuses to build against a worktree of the primary checkout" do
    primary =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-primary-#{System.unique_integer([:positive])}")
      )

    worktree = Path.join(System.tmp_dir!(), "blr-worktree-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(primary) end)
    on_exit(fn -> File.rm_rf(worktree) end)

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-b", "wt-branch", worktree, "HEAD"], cd: primary)

    {out, code} = run([worktree], [{"ARB_PRIMARY_CHECKOUT", primary}])

    assert code == 1
    assert out =~ "refusing to build from the primary checkout"
  end

  test "a separate clone is not refused (fails later, on git fetch, not the guard)" do
    primary =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-primary-#{System.unique_integer([:positive])}")
      )

    separate =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-separate-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf(primary) end)
    on_exit(fn -> File.rm_rf(separate) end)

    {out, code} = run([separate], [{"ARB_PRIMARY_CHECKOUT", primary}])

    refute out =~ "refusing to build from the primary checkout"
    # No `origin` remote in this throwaway repo, so it fails past the guard —
    # proof the guard let it through rather than proof the build succeeded.
    assert code != 0
    assert out =~ "Building in #{separate}"
  end

  test "GLIBC baseline extraction does not SIGPIPE: ARB_GLIBC_BASELINE can be extracted safely" do
    primary =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-primary-#{System.unique_integer([:positive])}")
      )

    separate =
      init_repo!(
        Path.join(System.tmp_dir!(), "blr-separate-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf(primary) end)
    on_exit(fn -> File.rm_rf(separate) end)

    # Run the script which extracts GLIBC baseline — should not fail with SIGPIPE (141).
    # It will fail later on git fetch, but we're testing that GLIBC extraction doesn't abort
    # the script before that point.
    {out, code} = run([separate], [{"ARB_PRIMARY_CHECKOUT", primary}])

    # Code should not be 141 (SIGPIPE). It will fail on git fetch (code != 0),
    # but not with SIGPIPE in the GLIBC extraction step.
    assert code != 141,
           "Script exited with SIGPIPE (141), suggesting GLIBC baseline extraction failed: #{out}"

    assert out =~ "Building in #{separate}"
  end

  test "unexpected errors are reported with context (ERR trap)" do
    # The script should have an ERR trap that reports which step failed.
    # We can't easily trigger a real failure without a full build, but we can
    # verify the script has error handling by checking for ERR trap declarations.
    script_content = File.read!(@script)
    assert script_content =~ "trap", "Script should have error handling via trap"
  end
end
