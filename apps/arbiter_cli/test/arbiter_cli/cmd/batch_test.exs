defmodule ArbiterCli.Cmd.BatchTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Batch

  @workspaces %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  test "list fetches convoys scoped to the workspace" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces, 200}},
      {{"get", "/api/convoys"},
       {%{"data" => [%{"id" => "bd-cv-1", "title" => "Onboarding", "status" => "open"}]}, 200}}
    ])

    {out, _err, code} = capture(fn -> Batch.run(["list", "--json"]) end)
    assert code == 0
    assert out =~ "bd-cv-1"
  end

  test "show delegates to the convoy show endpoint" do
    stub_get("/api/convoys/bd-cv-1", %{"id" => "bd-cv-1", "title" => "T", "status" => "open"})
    {out, _err, code} = capture(fn -> Batch.run(["show", "bd-cv-1", "--json"]) end)
    assert code == 0
    assert out =~ "bd-cv-1"
  end

  test "remove delegates to the member-delete endpoint" do
    stub_delete("/api/convoys/bd-cv-1/members/bd-2", %{"id" => "bd-cv-1"}, 200)
    {out, _err, code} = capture(fn -> Batch.run(["remove", "bd-cv-1", "bd-2", "--json"]) end)
    assert code == 0
    assert out =~ "bd-cv-1"
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Batch.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown batch subcommand"
  end
end
