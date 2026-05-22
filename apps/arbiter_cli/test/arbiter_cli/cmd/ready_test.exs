defmodule ArbiterCli.Cmd.ReadyTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Ready

  defp stub_two(ready_data) do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"get", "/api/issues/ready"}, {%{"data" => ready_data}, 200}}
    ])
  end

  test "lists ready issues from the active workspace by default" do
    stub_two([%{"id" => "a", "status" => "open", "priority" => 1, "title" => "ready one"}])

    {out, _err, exit_code} = capture(fn -> Ready.run([]) end)
    assert exit_code == 0
    assert out =~ "ready one"
  end

  test "empty list prints placeholder" do
    stub_two([])
    {out, _err, _} = capture(fn -> Ready.run([]) end)
    assert out =~ "(no beads)"
  end

  test "--all skips the workspace filter" do
    stub_two([%{"id" => "all-1", "status" => "open", "priority" => 1, "title" => "cross-ws"}])

    {out, _err, exit_code} = capture(fn -> Ready.run(["--all"]) end)
    assert exit_code == 0
    assert out =~ "cross-ws"
  end
end
