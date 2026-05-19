defmodule GtElixirCli.Cmd.UpdateTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Update

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

  test "no fields supplied → error" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "at least one field flag"
  end
end
