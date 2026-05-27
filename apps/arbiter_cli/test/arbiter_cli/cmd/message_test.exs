defmodule ArbiterCli.Cmd.MessageTest do
  use ArbiterCli.CliCase, async: false

  @workspaces %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  describe "arb message <bead-id> <text>" do
    test "sends a direction to the bead" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-1", "kind" => "direction"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz", "check", "the", "API"]) end)

      assert code == 0
      assert out =~ "Direction sent to bd-xyz."
    end

    test "requires text after the bead id" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz"]) end)
      assert code != 0
      assert err =~ "message requires text"
    end

    test "requires a bead id" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Message.run([]) end)
      assert code != 0
      assert err =~ "message requires"
    end

    test "--json emits the created message" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-1", "kind" => "direction"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz", "do", "the", "thing", "--json"]) end)

      assert code == 0
      assert {:ok, %{"id" => "m-1"}} = Jason.decode(out)
    end
  end
end
