defmodule ArbiterCli.Cmd.SyncTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Sync

  @workspace_lookup {{"get", "/api/workspaces"},
                     {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]},
                      200}}

  test "--dry GETs the plan and prints it" do
    stub_routes([
      @workspace_lookup,
      {{"get", "/api/workspaces/ws-1/sync/plan"},
       {%{
          "data" => [
            %{"action" => "create", "ref" => "43", "title" => "Wire it up"},
            %{"action" => "close", "bead_id" => "bd-old", "reason" => "tracker closed"}
          ]
        }, 200}}
    ])

    {out, _err, code} = capture(fn -> Sync.run(["--dry"]) end)
    assert code == 0
    assert out =~ "Sync plan"
    assert out =~ "create bead for #43"
    assert out =~ "close bd-old"
  end

  test "default mode POSTs and prints results" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/sync"},
       {%{
          "data" => [%{"action" => "create", "ref" => "43", "title" => "X"}],
          "results" => [
            %{
              "outcome" => "created",
              "bead" => %{"id" => "bd-new", "tracker_type" => "github", "tracker_ref" => "43"}
            }
          ],
          "applied" => true
        }, 200}}
    ])

    {out, _err, code} = capture(fn -> Sync.run([]) end)
    assert code == 0
    assert out =~ "Sync:"
    assert out =~ "created bd-new"
  end

  test "empty plan prints friendly message" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/sync"}, {%{"data" => [], "applied" => true}, 200}}
    ])

    {out, _err, code} = capture(fn -> Sync.run([]) end)
    assert code == 0
    assert out =~ "nothing to do"
  end

  test "--json mode emits JSON" do
    stub_routes([
      @workspace_lookup,
      {{"get", "/api/workspaces/ws-1/sync/plan"}, {%{"data" => []}, 200}}
    ])

    {out, _err, code} = capture(fn -> Sync.run(["--dry", "--json"]) end)
    assert code == 0
    assert {:ok, _} = Jason.decode(String.trim(out))
  end
end
