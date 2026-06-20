defmodule ArbiterCli.Cmd.CreateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Create

  test "creates issue using workspace lookup" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{"id" => "bd-001", "title" => "Hello", "status" => "open", "priority" => 2}, 201}}
    ])

    {out, _err, exit_code} = capture(fn -> Create.run(["Hello"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "Hello"
  end

  test "--parent attaches the new issue to the parent task via a parent_of edge" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"}, {%{"id" => "bd-007", "title" => "X"}, 201}},
      {{"post", "/api/dependencies"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:dep_body, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "dep-1"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Create.run(["X", "--parent", "bd-epic"]) end)

    assert exit_code == 0
    assert out =~ "bd-007"

    assert_receive {:dep_body,
                    %{
                      "from_issue_id" => "bd-epic",
                      "to_issue_id" => "bd-007",
                      "type" => "parent_of"
                    }}
  end

  test "--parent attach failure surfaces and exits non-zero" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"}, {%{"id" => "bd-007", "title" => "X"}, 201}},
      {{"post", "/api/dependencies"},
       {%{"error" => %{"type" => "not_found", "message" => "resource not found"}}, 404}}
    ])

    {_out, err, exit_code} =
      capture(fn -> Create.run(["X", "--parent", "bd-epic"]) end)

    assert exit_code == 4
    assert err =~ "failed to attach bd-007 to parent bd-epic"
  end

  test "no title argument exits non-zero" do
    {_out, err, exit_code} = capture(fn -> Create.run([]) end)
    assert exit_code == 1
    assert err =~ "title"
  end

  test "--json emits JSON" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"}, {%{"id" => "bd-001", "title" => "X"}, 201}}
    ])

    {out, _err, exit_code} = capture(fn -> Create.run(["X", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"id" => "bd-001"}} = Jason.decode(String.trim(out))
  end

  test "no workspace named default → friendly error" do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => []}, 200}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X"]) end)
    assert exit_code == 1
    assert err =~ "no workspace named"
  end

  test "validation error from server surfaces message" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{
          "error" => %{
            "type" => "validation_error",
            "message" => "validation failed",
            "details" => %{}
          }
        }, 422}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X"]) end)
    assert exit_code == 1
    assert err =~ "validation failed"
  end

  test "--tracker-ref passes the ref through as tracker_ref" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-002", "title" => "Bound", "tracker_ref" => "777"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Create.run(["Bound", "--tracker-ref", "777", "--json"]) end)

    assert exit_code == 0
    assert {:ok, %{"tracker_ref" => "777"}} = Jason.decode(String.trim(out))

    assert_received {:posted, body}
    assert body["tracker_ref"] == "777"
    refute Map.has_key?(body, "skip_upstream_create")
  end

  test "--no-tracker forwards skip_upstream_create=true to the create action" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-003", "title" => "Local"})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["Local", "--no-tracker"]) end)
    assert exit_code == 0

    assert_received {:posted, body}
    assert body["skip_upstream_create"] == true
  end

  test "--target-branch forwards as target_branch in the POST body" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-010", "title" => "T", "target_branch" => "dolphin"})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Create.run(["T", "--target-branch", "dolphin"]) end)

    assert exit_code == 0

    assert_received {:posted, body}
    assert body["target_branch"] == "dolphin"
  end

  test "--difficulty forwards as difficulty in the POST body" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-005", "title" => "Hard", "difficulty" => 3})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["Hard", "--difficulty", "3"]) end)
    assert exit_code == 0

    assert_received {:posted, body}
    assert body["difficulty"] == 3
  end

  test "--difficulty out-of-range exits non-zero before posting" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--difficulty", "9"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"
  end

  test "upstream-create failure (502 with task body + error) surfaces non-zero" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{
          "issue" => %{"id" => "bd-004", "title" => "Half"},
          "error" => %{
            "type" => "upstream_create_failed",
            "message" => "task bd-004 created locally but upstream github create failed: boom",
            "details" => %{"task_id" => "bd-004", "tracker_type" => "github"}
          }
        }, 502}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["Half"]) end)
    assert exit_code != 0
    assert err =~ "upstream"
    assert err =~ "bd-004"
  end

  describe "--ticket-only" do
    test "posts to /api/workspaces/:id/tracker/tickets and prints ref + url" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "ref" => "99",
             "url" => "https://github.com/o/r/issues/99",
             "tracker_type" => "github"
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> Create.run(["Unclaimed ticket", "--ticket-only"]) end)

      assert exit_code == 0
      assert out =~ "99"
      assert out =~ "github"

      assert_received {:posted, body}
      assert body["title"] == "Unclaimed ticket"
      refute Map.has_key?(body, "workspace_id")
    end

    test "--no-task alias works the same as --ticket-only" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "77",
            "url" => "https://github.com/o/r/issues/77",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["No-task title", "--no-task"]) end)
      assert exit_code == 0
      assert out =~ "77"
    end

    test "--unclaimed alias works the same as --ticket-only" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "55",
            "url" => "https://github.com/o/r/issues/55",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["Unclaimed", "--unclaimed"]) end)
      assert exit_code == 0
      assert out =~ "55"
    end

    test "--json emits JSON" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "42",
            "url" => "https://github.com/o/r/issues/42",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} =
        capture(fn -> Create.run(["My ticket", "--ticket-only", "--json"]) end)

      assert exit_code == 0
      assert {:ok, %{"ref" => "42", "tracker_type" => "github"}} = Jason.decode(String.trim(out))
    end

    test "forwards --description and --assignee to the tickets endpoint" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"ref" => "10", "url" => nil, "tracker_type" => "github"})
         end}
      ])

      {_out, _err, exit_code} =
        capture(fn ->
          Create.run([
            "Detailed",
            "--ticket-only",
            "--description",
            "some body",
            "--assignee",
            "alice"
          ])
        end)

      assert exit_code == 0
      assert_received {:posted, body}
      assert body["description"] == "some body"
      assert body["assignee"] == "alice"
    end

    test "--ticket-only and --no-tracker errors before posting" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only", "--no-tracker"]) end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end

    test "--ticket-only and --local-only errors before posting" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only", "--local-only"]) end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end

    test "server error (e.g. no tracker configured) surfaces non-zero" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "error" => %{
              "type" => "invalid_request",
              "message" => "workspace has no tracker configured",
              "details" => %{}
            }
          }, 400}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only"]) end)

      assert exit_code != 0
      assert err =~ "tracker"
    end
  end
end
