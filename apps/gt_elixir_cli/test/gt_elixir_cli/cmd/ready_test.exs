defmodule GtElixirCli.Cmd.ReadyTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Ready

  test "lists ready issues" do
    stub_get("/api/issues/ready", %{
      "data" => [%{"id" => "a", "status" => "open", "priority" => 1, "title" => "ready one"}]
    })

    {out, _err, exit_code} = capture(fn -> Ready.run([]) end)
    assert exit_code == 0
    assert out =~ "ready one"
  end

  test "empty list prints placeholder" do
    stub_get("/api/issues/ready", %{"data" => []})
    {out, _err, _} = capture(fn -> Ready.run([]) end)
    assert out =~ "(no issues)"
  end
end
