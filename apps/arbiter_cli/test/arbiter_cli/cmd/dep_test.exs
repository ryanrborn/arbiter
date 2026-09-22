defmodule ArbiterCli.Cmd.DepTest do
  # async: false — the ARB_WORKSPACE test below mutates a process-global env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Dep

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

  # bd-6bax7s: `conflicts_with` is honoured by both schedulers now, and the
  # help is where a coordinator at a terminal finds that out.
  test "dep --help documents the edge types and who honours the mutex" do
    {out, _err, exit_code} = capture(fn -> Dep.run(["--help"]) end)

    assert exit_code == 0
    assert out =~ "conflicts_with"
    # bd-a14qd1: the board scheduler is the only dispatcher, so it is the only
    # thing that can enforce the mutex — help must not promise a second one.
    assert out =~ "board scheduler"
    refute out =~ "Conductor"
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

  defp dep_row(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "d1",
        "from_issue_id" => "a",
        "to_issue_id" => "b",
        "type" => "conflicts_with",
        "from" => %{"id" => "a", "title" => "task A", "status" => "open", "priority" => 2},
        "to" => %{"id" => "b", "title" => "task B", "status" => "closed", "priority" => 1}
      },
      overrides
    )
  end

  test "dep list with no argument lists the active workspace's edges" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"get", "/api/dependencies"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["workspace_id"] == "ws-1"
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => [dep_row()]})
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Dep.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "task A"
    assert out =~ "task B"
    assert out =~ "conflicts_with"
  end

  test "dep list <issue> lists that issue's edges" do
    stub_get("/api/dependencies/a", %{"data" => [dep_row()]})

    {out, _err, exit_code} = capture(fn -> Dep.run(["list", "a"]) end)
    assert exit_code == 0
    assert out =~ "task A"
    assert out =~ "task B"
  end

  test "dep list --type filters" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"get", "/api/dependencies"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["type"] == "conflicts_with"
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => [dep_row()]})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Dep.run(["list", "--type", "conflicts_with"]) end)
    assert exit_code == 0
  end

  test "dep list --json emits raw JSON" do
    stub_get("/api/dependencies/a", %{"data" => [dep_row()]})

    {out, _err, exit_code} = capture(fn -> Dep.run(["list", "a", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"data" => [_row]}} = Jason.decode(out)
  end

  # `--workspace`/`ARB_WORKSPACE` resolution itself is `main.ex`'s job (it
  # strips `-w`/`--workspace` before any subcommand runs); `dep list` just
  # has to honor `ARB_WORKSPACE` like `arb ready` does.
  test "dep list honors ARB_WORKSPACE" do
    prev = System.get_env("ARB_WORKSPACE")
    System.put_env("ARB_WORKSPACE", "other")

    try do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "other-ws", "name" => "other", "prefix" => "oth"}]}, 200}},
        {{"get", "/api/dependencies"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["workspace_id"] == "other-ws"
           conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
         end}
      ])

      {_out, _err, exit_code} = capture(fn -> Dep.run(["list"]) end)
      assert exit_code == 0
    after
      if prev, do: System.put_env("ARB_WORKSPACE", prev), else: System.delete_env("ARB_WORKSPACE")
    end
  end

  test "dep list with too many arguments errors" do
    {_out, err, exit_code} = capture(fn -> Dep.run(["list", "a", "b"]) end)
    assert exit_code == 1
    assert err =~ "at most one argument"
  end
end
