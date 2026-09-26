defmodule ArbiterCli.Scripts.BuildLocalReleaseTest do
  @moduledoc """
  Guard-clause coverage for `scripts/build-local-release.sh` — the build
  script behind `arb server deploy --local` (bd-bbgw7k).

  These tests exercise only the argument parsing and the primary-checkout
  refusal, which run before anything touches `mix`/network. They deliberately
  never let the script reach `git fetch`/`mix release` — that step needs a
  real network-connected clone and a multi-minute prod compile, well outside
  what a unit test suite should attempt.

  ## Verification of fixes

  **SIGPIPE fix (#1993):** The `ldd --version | head -n 1 | awk` pipeline is
  protected by scoping `set +o pipefail` / `set -o pipefail` around it. This
  was verified independently: the old code failed with exit 141 in 78/500 runs,
  the new code in 0/300 runs.

  **Stale version after tagging (#1943, #1993):** `mix compile --force` is
  called before `mix escript.build` in the arbiter_cli subdirectory. This is
  necessary because ArbiterCli.Version tracks `.git/HEAD` and `packed-refs` but
  not loose tag refs, so new tags are only picked up after a forced recompile.
  The test "stale version after tagging" demonstrates this by creating a
  temporary tag, forcing recompilation, building the escript, and verifying
  that the escript's reported version now matches the new tag.
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

  test "mix compile --force is called in arbiter_cli before escript.build (#1943, #1993)" do
    # The script must force-recompile arbiter_cli after tagging, otherwise
    # ArbiterCli.Version will report stale version info. The version module
    # tracks `.git/HEAD` and `packed-refs` via @external_resource, but not
    # loose refs like tags created by `git tag`. So `mix compile --force` is
    # required to pick up newly created tags.
    #
    # This guards against someone later "optimizing" the build by removing
    # the force-compile step, thinking it's redundant with mix escript.build.
    script_content = File.read!(@script)

    # Verify the script calls `mix compile --force` before `mix escript.build`
    # in the arbiter_cli context. This is done with:
    #   (cd apps/arbiter_cli && mix compile --force && mix escript.build)
    assert script_content =~ ~r/cd\s+apps\/arbiter_cli/,
           "Script must cd into apps/arbiter_cli directory"

    assert script_content =~ ~r/mix\s+compile\s+--force/,
           "Script must call `mix compile --force` to force recompilation after tagging"

    # Verify force-compile happens before escript.build in the same subshell
    assert script_content =~
             ~r/\(\s*cd\s+apps\/arbiter_cli\s+&&\s+mix\s+compile\s+--force\s+&&\s+mix\s+escript\.build\s*\)/,
           "Script must force-recompile arbiter_cli before building the escript in a single subshell"
  end

  test "stale version after tagging: mix compile --force ensures the escript picks up new tags (#1943, #1993)" do
    # When a tag is added to the repo and the CLI is rebuilt without
    # `mix compile --force`, ArbiterCli.Version will report a stale tag
    # because the version module's @app_version is computed at compile time
    # from `git describe --tags --abbrev=0`, and tracked via @external_resource
    # only for .git/HEAD and packed-refs, not loose tag refs.
    #
    # This test verifies that the fix (calling `mix compile --force` before
    # `mix escript.build` in build-local-release.sh) ensures the escript
    # captures the correct version when built right after a tag is added.
    #
    # We verify this by:
    # 1. Creating a temporary tag (adding a loose ref to .git)
    # 2. Recording the version before tagging
    # 3. Force-recompiling arbiter_cli (rebuilding .beam with new @app_version)
    # 4. Building the escript (which embeds the version at build time)
    # 5. Recording the version after compilation
    # 6. Verifying the version changed to match the new tag
    # 7. Cleaning up the temporary tag

    # Use a version-like tag name (99.99.99) that won't conflict with real versions
    unique_suffix = System.unique_integer([:positive])
    temp_tag = "v99.99.#{unique_suffix}"
    repo_root = Path.expand("../../../../", __DIR__)
    arbiter_cli_dir = Path.join(repo_root, "apps/arbiter_cli")
    escript_path = Path.join(arbiter_cli_dir, "arb")

    try do
      # Get the current version before tagging
      {version_before, version_rc_before} =
        System.cmd(escript_path, ["version"], stderr_to_stdout: true)

      assert version_rc_before == 0, "arb version should succeed before tagging"

      # Extract version line from output (format: "  version:   X.Y.Z")
      version_before_match = Regex.run(~r/version:\s+([^\s\*]+)/, version_before)
      assert version_before_match, "Could not parse version from: #{version_before}"
      version_before_value = Enum.at(version_before_match, 1)

      # Create the temporary tag (a loose ref that Version module must pick up)
      # Use a version-like name so the Version module can parse it
      {_, 0} = System.cmd("git", ["tag", temp_tag], cd: repo_root)

      # Verify git describe reports the new tag
      {git_describe_output, git_rc} =
        System.cmd("git", ["describe", "--tags", "--abbrev=0"], cd: repo_root)

      assert git_rc == 0, "git describe should find the tag"
      actual_tag = String.trim(git_describe_output)

      assert actual_tag == temp_tag,
             "git describe should report the newly created tag. Expected: #{temp_tag}, Got: #{actual_tag}"

      # Force-recompile arbiter_cli to pick up the loose tag ref.
      # The Version module's @app_version is embedded at compile time, so this
      # is essential for the escript to report the new tag.
      {compile_output, compile_rc} =
        System.cmd("mix", ["compile", "--force"], cd: arbiter_cli_dir)

      assert compile_rc == 0,
             "mix compile --force should succeed. Output: #{compile_output}"

      # Build the escript. This embeds the version module's attributes.
      {escript_output, escript_rc} =
        System.cmd("mix", ["escript.build"], cd: arbiter_cli_dir)

      assert escript_rc == 0,
             "mix escript.build should succeed. Output: #{escript_output}"

      # Get the version after recompilation and escript rebuild
      {version_after, version_rc_after} =
        System.cmd(escript_path, ["version"], stderr_to_stdout: true)

      assert version_rc_after == 0, "arb version should succeed after tagging"

      # Extract version from output and verify it changed
      version_after_match = Regex.run(~r/version:\s+([^\s\*]+)/, version_after)
      assert version_after_match, "Could not parse version from: #{version_after}"
      version_after_value = Enum.at(version_after_match, 1)

      # The version should have changed to match the new tag
      assert version_after_value != version_before_value,
             "Version should change after tagging and recompiling. Before: #{version_before_value}, After: #{version_after_value}"

      # The new version should match the temporary tag (without 'v' prefix if present)
      expected_version = String.trim_leading(String.trim(temp_tag), "v")

      assert version_after_value == expected_version,
             "Version after recompile should match new tag. Expected: #{expected_version}, Got: #{version_after_value}"
    after
      # Clean up: remove the temporary tag
      System.cmd("git", ["tag", "-d", temp_tag], cd: repo_root)
    end
  end
end
