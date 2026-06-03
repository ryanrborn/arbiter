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

  describe "--tracker-ref" do
    test "passes tracker_ref through to the server payload" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           send(parent, {:posted, decoded})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "id" => "bd-002",
             "title" => "bound",
             "tracker_type" => "github",
             "tracker_ref" => decoded["tracker_ref"]
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> Create.run(["bound", "--tracker-ref", "42"]) end)

      assert exit_code == 0
      assert out =~ "bd-002"
      assert_receive {:posted, payload}
      assert payload["tracker_ref"] == "42"
      refute Map.has_key?(payload, "tracker_type")
    end
  end

  describe "--no-tracker" do
    test "forces tracker_type=none in the payload" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           send(parent, {:posted, decoded})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "id" => "bd-003",
             "title" => "local",
             "tracker_type" => "none"
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["local", "--no-tracker"]) end)

      assert exit_code == 0
      assert out =~ "bd-003"
      assert_receive {:posted, payload}
      assert payload["tracker_type"] == "none"
      refute Map.has_key?(payload, "tracker_ref")
    end
  end

  describe "--tracker-ref and --no-tracker are mutually exclusive" do
    test "supplying both exits with a clear message" do
      {_out, err, exit_code} =
        capture(fn -> Create.run(["X", "--tracker-ref", "1", "--no-tracker"]) end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end
  end

  describe "upstream-failure error from server" do
    test "tracker_upstream_create_failed surfaces a clear message and exits non-zero" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         {%{
            "error" => %{
              "type" => "tracker_upstream_create_failed",
              "message" =>
                "bead bd-xyz created locally, but failed to create upstream github issue: HTTP 422",
              "details" => %{
                "bead_id" => "bd-xyz",
                "tracker_type" => "github",
                "upstream_ref" => nil
              }
            }
          }, 502}}
      ])

      {_out, err, exit_code} = capture(fn -> Create.run(["fail"]) end)

      assert exit_code == 1
      assert err =~ "bead bd-xyz created locally"
      assert err =~ "github"
    end
  end
end
