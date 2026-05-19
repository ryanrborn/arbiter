defmodule GtElixirCli.Cmd.DepTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Dep

  test "dep add creates the dependency" do
    stub_post(
      "/api/dependencies",
      %{"id" => "d1", "from_issue_id" => "a", "to_issue_id" => "b", "type" => "blocks"},
      201
    )

    {out, _err, exit_code} = capture(fn -> Dep.run(["add", "a", "blocks", "b"]) end)
    assert exit_code == 0
    assert out =~ "a"
    assert out =~ "blocks"
    assert out =~ "b"
  end

  test "dep rm hits DELETE" do
    stub_delete("/api/dependencies/a/b", "", 204)

    {out, _err, exit_code} = capture(fn -> Dep.run(["rm", "a", "b"]) end)
    assert exit_code == 0
    assert out =~ "removed dependency edge"
  end

  test "dep rm with --type passes type as query" do
    stub_routes([
      {{"delete", "/api/dependencies/a/b"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["type"] == "blocks"
         conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Dep.run(["rm", "a", "b", "--type", "blocks"]) end)
    assert exit_code == 0
  end

  test "dep with no subcommand errors" do
    {_out, err, exit_code} = capture(fn -> Dep.run([]) end)
    assert exit_code == 1
    assert err =~ "subcommand"
  end

  test "dep add with missing args errors" do
    {_out, err, exit_code} = capture(fn -> Dep.run(["add", "a"]) end)
    assert exit_code == 1
    assert err =~ "requires"
  end
end
