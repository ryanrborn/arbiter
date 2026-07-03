defmodule ArbiterCli.Cmd.UpdateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Update

  test "updates priority via PATCH" do
    stub_patch(
      "/api/issues/bd-001",
      %{"id" => "bd-001", "title" => "X", "priority" => 0, "status" => "open"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--priority", "0"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "append-notes fetches first, then patches with combined notes" do
    stub_routes([
      {{"get", "/api/issues/bd-001"},
       {%{"id" => "bd-001", "title" => "X", "notes" => "prior"}, 200}},
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         # assert that combined notes ended up in the payload
         assert decoded["notes"] =~ "prior"
         assert decoded["notes"] =~ "addendum"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "notes" => decoded["notes"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--append-notes", "addendum"]) end)

    assert exit_code == 0
  end

  test "--qa-notes and --deployment-notes are sent as fields" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["qa_notes"] == "verify the endpoint"
         assert decoded["deployment_notes"] == "no migrations"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "qa_notes" => decoded["qa_notes"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run([
          "bd-001",
          "--qa-notes",
          "verify the endpoint",
          "--deployment-notes",
          "no migrations"
        ])
      end)

    assert exit_code == 0
  end

  test "--pr-body is sent as the pr_body field (bd-53xrmi)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["pr_body"] == "## Summary\nDid the thing."

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "pr_body" => decoded["pr_body"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--pr-body", "## Summary\nDid the thing."])
      end)

    assert exit_code == 0
  end

  test "no fields supplied → error" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "at least one field flag"
  end

  test "updates difficulty via PATCH" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["difficulty"] == 3

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "difficulty" => 3})
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "3"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "--difficulty out-of-range exits non-zero before patching" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "7"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"
  end

  test "--acceptance is sent as the acceptance field" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["acceptance"] == "- Verify the new endpoint works\n- Write tests"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "acceptance" => decoded["acceptance"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--acceptance", "- Verify the new endpoint works\n- Write tests"])
      end)

    assert exit_code == 0
  end
end
