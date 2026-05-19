defmodule GtElixirCli.Cmd.CreateTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Create

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
end
