defmodule GtElixirCli.Cmd.WhereTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Where

  test "prints api host and active workspace" do
    stub_get("/api/workspaces", %{
      "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
    })

    {out, _err, exit_code} = capture(fn -> Where.run([]) end)
    assert exit_code == 0
    assert out =~ "api host:"
    assert out =~ "workspace:"
    assert out =~ "default"
    assert out =~ "ws-1"
  end

  test "--json emits structured info" do
    stub_get("/api/workspaces", %{
      "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
    })

    {out, _err, exit_code} = capture(fn -> Where.run(["--json"]) end)
    assert exit_code == 0

    assert {:ok, %{"base_url" => _, "workspace" => %{"id" => "ws-1"}}} =
             Jason.decode(String.trim(out))
  end
end
