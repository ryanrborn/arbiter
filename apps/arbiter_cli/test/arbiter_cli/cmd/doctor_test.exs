defmodule ArbiterCli.Cmd.DoctorTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Doctor

  @workspaces_resp %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  @repos_resp %{
    "data" => [
      %{"name" => "tonic", "source" => "default", "path" => "/srv/tonic"}
    ]
  }

  # Use the actual compiled CLI version so the version check passes in all-green tests.
  defp matching_version_resp do
    %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }
  end

  test "all-green when Phoenix responds with a workspace named default" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[ ok ] version"
    assert out =~ "[ ok ] migrations up to date"
  end

  test "pending migrations shows [fail] with count in detail" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "warning", "pending_count" => 3}, 200}}
    ])

    {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
    assert out =~ "[fail] migrations up to date"
    assert out =~ "3 pending"
  end

  test "unreachable DB or DB error shows [fail] with 'could not check'" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"},
       {%{"status" => "unknown", "pending_count" => nil, "error" => "unreachable"}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] migrations up to date"
    assert out =~ "could not check"
    refute out =~ "[ ok ] migrations up to date"
  end

  # bd-337f2i round 1 regression: a server predating the migrations endpoint
  # returns 404, landing exactly in the mid-deploy version-skew window this
  # check exists for — that must not be a hard [fail], consistent with how
  # check_versions/0 treats server errors.
  test "server without the migrations endpoint (404) does not fail doctor" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{}, 404}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] migrations up to date"
  end

  test "unexpected migrations response shape does not crash doctor" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"unexpected" => "shape"}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] migrations up to date"
  end

  test "connection refused → all fail with actionable hint" do
    stub_transport_error(:get, "/api/workspaces", :econnrefused)

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 1
    assert out =~ "[fail] phoenix reachable"
    assert out =~ "mix phx.server"
  end

  test "no workspaces → workspace check fails with hint" do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => []}, 200}},
      {{"get", "/api/repos"}, {%{"data" => []}, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 1
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[fail] at least one workspace exists"
    assert out =~ "seeds.exs"
  end

  test "--json emits structured payload" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"ok" => true, "checks" => checks}} = Jason.decode(String.trim(out))
    assert is_list(checks)
    assert length(checks) == 6
  end

  test "version mismatch is non-fatal (exit 0 but shows [fail])" do
    mismatched_version_resp = %{
      "version" => "9.9.9",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[fail] version"
    assert out =~ "server 9.9.9"
    assert out =~ "CLI #{ArbiterCli.Version.app_version()}"
    refute out =~ "CLI and server match"
  end

  test "version mismatch does not block arb start readiness" do
    mismatched_version_resp = %{
      "version" => "9.9.9",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    assert Doctor.green?() == true
  end

  test "release build (SHA unavailable) with matching version shows [ ok ]" do
    # When the server is an OTP release, it may report sha: "unknown" because
    # no git process is available at runtime. If the semantic version matches
    # the CLI, the check should pass — this is the expected state after
    # `arb server deploy`.
    release_version_resp = %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] version"
    assert out =~ "CLI and server match"
  end

  test "release build (SHA unavailable) with matching version is fully green" do
    release_version_resp = %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    assert Doctor.green?() == true
  end

  test "release build (SHA unavailable) with mismatched version shows [fail] but is non-fatal" do
    # Regression for the false-green bug: both CLI and server report
    # sha: "unknown" in this scenario (neither has git at runtime), so a SHA
    # comparison alone would spuriously report a match. The version numbers
    # must actually be compared.
    release_version_resp = %{
      "version" => "0.0.1",
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    assert out =~ "server 0.0.1"
    assert out =~ "CLI #{ArbiterCli.Version.app_version()}"
    refute out =~ "CLI and server match"
    assert Doctor.green?() == true
  end

  test "workspace resolution failure is an operator-actionable exit 1, but must not block deploy readiness" do
    prev = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")
    on_exit(fn -> if prev, do: System.put_env("ARB_WORKSPACE", prev) end)

    ambiguous_workspaces = %{
      "data" => [
        %{"id" => "ws-a", "name" => "alpha", "prefix" => "al"},
        %{"id" => "ws-b", "name" => "beta", "prefix" => "be"}
      ]
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {ambiguous_workspaces, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    # `arb doctor` still exits non-zero — this is an operator-actionable
    # misconfiguration, same as any other broken `Workspace.resolve/0` caller.
    assert exit_code == 1
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[fail] active workspace resolves"
    # ...but it must never gate `arb server deploy`'s auto-rollback wait
    # (bd-8ix2tw): an unresolvable workspace selector says nothing about
    # whether the deployed server itself is healthy.
    assert Doctor.green?() == true
  end

  test "server on the same SHA the CLI's own build carries, but a different version, is a real mismatch" do
    # Guards the exact bug: `cli_sha == server_sha` (e.g. both literally
    # "unknown") must never by itself imply the versions match.
    same_sha_diff_version_resp = %{
      "version" => "9.9.9",
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {same_sha_diff_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    refute out =~ "CLI and server match"
  end

  test "surfaces a failed-swap mismatch: server still on the pre-deploy version" do
    # The failed-swap case from the ticket: the CLI has just been upgraded to
    # the version being deployed, but the server's /api/version shows the
    # swap/restart never actually took (still reporting the prior release).
    just_deployed_vsn = ArbiterCli.Version.app_version()

    stale_server_resp = %{
      "version" => "0.0.1",
      "sha" => "unknown",
      "built_at" => "2023-01-01T00:00:00Z",
      "booted_at" => "2023-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {stale_server_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    assert out =~ "server 0.0.1"
    assert out =~ "CLI #{just_deployed_vsn}"
    refute out =~ "CLI and server match"
    # Non-fatal: a version check on its own must not gate `arb server deploy`'s
    # auto-rollback — only Phoenix/workspace reachability does.
    assert Doctor.green?() == true
  end

  # ---- repo config check (bd-3pqzsa) --------------------------------------
  #
  # v0.1.56 dropped the `rig_paths` fallback, so an un-migrated install
  # resolved zero repos while doctor stayed 5/5 green. Zero repos is now an
  # explicit, failing line.

  describe "repos resolved check" do
    test "reports the repo count on a healthy install" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] repos resolved"
      assert out =~ "1 repo(s)"
    end

    test "zero repos with a workspace present is a failing, actionable line" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] repos resolved"
      assert out =~ "no repos registered"
      assert out =~ "repo_paths"
    end

    test "zero repos names the legacy rig_paths key when a workspace still carries it" do
      legacy_workspaces = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"rig_paths" => %{"tonic" => "/srv/tonic"}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {legacy_workspaces, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] repos resolved"
      assert out =~ "rig_paths"
      assert out =~ "arbiter.migrate_rig_paths"
    end

    test "zero repos is not a deploy-rollback signal" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      # An empty repo map says nothing about whether the *deployed server* is
      # healthy — it must never auto-roll-back a deploy (cf. bd-8ix2tw).
      assert Doctor.green?() == true
    end

    test "no workspaces at all does not double-report as a repo failure" do
      stub_routes([
        {{"get", "/api/workspaces"}, {%{"data" => []}, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] repos resolved"
      assert out =~ "no workspaces"
    end
  end
end
