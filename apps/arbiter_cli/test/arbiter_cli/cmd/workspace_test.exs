defmodule ArbiterCli.Cmd.WorkspaceTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Workspace

  test "list renders the configured workspaces" do
    stub_get("/api/workspaces", %{
      "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
    })

    {out, _err, code} = capture(fn -> Workspace.run(["list"]) end)
    assert code == 0
    assert out =~ "default"
    assert out =~ "prefix=bd"
  end

  test "show renders one workspace" do
    stub_get("/api/workspaces/ws-1", %{"id" => "ws-1", "name" => "default", "prefix" => "bd"})

    {out, _err, code} = capture(fn -> Workspace.run(["show", "ws-1"]) end)
    assert code == 0
    assert out =~ "default"
  end

  test "show requires an id" do
    {_out, err, code} = capture(fn -> Workspace.run(["show"]) end)
    assert code == 1
    assert err =~ "workspace show requires"
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Workspace.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown workspace subcommand"
  end

  describe "secret" do
    defp stub_one_workspace(secret_keys) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => secret_keys}
        ]
      })
    end

    test "secret ls lists configured key names" do
      stub_one_workspace(["tracker_token", "merge_token"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "tracker_token"
      assert out =~ "merge_token"
    end

    test "secret ls reports when none are set" do
      stub_one_workspace([])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "(no secrets)"
    end

    test "secret set patches the workspace and echoes the resulting keys" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => []}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         {%{"id" => "ws-1", "secret_keys" => ["tracker_token"]}, 200}}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "sct_rw_x", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "tracker_token"
      # The token value is never printed back.
      refute out =~ "sct_rw_x"
    end

    test "secret set requires a value" do
      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "requires <key> <value>"
    end

    test "secret rm removes an existing key" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "secret_keys" => ["tracker_token"]
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"}, {%{"id" => "ws-1", "secret_keys" => []}, 200}}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "ok"
    end

    test "secret rm rejects an unknown key" do
      stub_one_workspace(["other"])

      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "no secret named"
    end

    test "unknown secret subcommand errors" do
      {_out, err, code} = capture(fn -> Workspace.run(["secret", "frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown workspace secret subcommand"
    end
  end
end
