defmodule ArbiterCli.Cmd.ClaimTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Claim

  @workspace_lookup {{"get", "/api/workspaces"},
                     {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]},
                      200}}

  test "missing ref exits non-zero" do
    {_out, err, code} = capture(fn -> Claim.run([]) end)
    assert code != 0
    assert err =~ "issue number"
  end

  test "too many positionals fail with usage" do
    {_out, err, code} = capture(fn -> Claim.run(["43", "44"]) end)
    assert code != 0
    assert err =~ "single positional"
  end

  test "happy path POSTs ref, prints created task" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "title" => "Wire it up",
            "status" => "open",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code == 0
    assert out =~ "Claimed bd-abc"
    assert out =~ "Wire it up"
    assert out =~ "github:43"
  end

  test "existing task → 'Already claimed'" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "existing",
          "task" => %{
            "id" => "bd-abc",
            "title" => "Wire it up",
            "status" => "in_progress",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 200}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code == 0
    assert out =~ "Already claimed: bd-abc"
  end

  test "--repo prints a dispatch tip" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "title" => "T",
            "status" => "open",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43", "--repo", "arbiter"]) end)
    assert code == 0
    assert out =~ "arb dispatch bd-abc arbiter"
  end

  test "--json emits JSON" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43", "--json"]) end)
    assert code == 0
    assert {:ok, decoded} = Jason.decode(String.trim(out))
    assert decoded["status"] == "created"
  end

  test "403 not_assigned propagates as die" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "error" => %{
            "type" => "not_assigned",
            "message" => "issue is not assigned to workspace user \"me\"",
            "details" => %{"viewer" => "me"}
          }
        }, 403}}
    ])

    {_out, err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code != 0
    assert err =~ "not assigned"
  end

  test "--difficulty forwards as difficulty in the POST body" do
    parent = self()

    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "status" => "created",
           "task" => %{
             "id" => "bd-abc",
             "title" => "Hard task",
             "status" => "open",
             "tracker_type" => "github",
             "tracker_ref" => "43",
             "difficulty" => 3
           }
         })
       end}
    ])

    {_out, _err, code} = capture(fn -> Claim.run(["43", "--difficulty", "3"]) end)
    assert code == 0

    assert_received {:posted, body}
    assert body["difficulty"] == 3
  end

  test "--difficulty out-of-range exits non-zero before posting" do
    stub_routes([
      @workspace_lookup
    ])

    {_out, err, code} = capture(fn -> Claim.run(["43", "--difficulty", "9"]) end)
    assert code != 0
    assert err =~ "difficulty"
  end
end
