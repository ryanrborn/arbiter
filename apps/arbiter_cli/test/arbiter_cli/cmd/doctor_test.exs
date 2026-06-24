defmodule ArbiterCli.Cmd.DoctorTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Doctor

  @workspaces_resp %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  # Use the actual compiled CLI SHA so the version check passes in all-green tests.
  defp matching_version_resp do
    %{
      "version" => "0.1.0",
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }
  end

  test "all-green when Phoenix responds with a workspace named default" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[ ok ] version"
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
      {{"get", "/api/version"}, {matching_version_resp(), 200}}
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
      {{"get", "/api/version"}, {matching_version_resp(), 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"ok" => true, "checks" => checks}} = Jason.decode(String.trim(out))
    assert is_list(checks)
    assert length(checks) == 4
  end

  test "version mismatch is non-fatal (exit 0 but shows [fail])" do
    mismatched_version_resp = %{
      "version" => "0.1.0",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[fail] version"
    assert out =~ "Rebuild the escript"
  end

  test "version mismatch does not block arb start readiness" do
    mismatched_version_resp = %{
      "version" => "0.1.0",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}}
    ])

    assert Doctor.green?() == true
  end
end
