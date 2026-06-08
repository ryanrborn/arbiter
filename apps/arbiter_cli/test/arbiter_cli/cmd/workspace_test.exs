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
end
