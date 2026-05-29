defmodule ArbiterCli.Cmd.MsgTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Msg

  @workspaces %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  # Echoes the decoded request body back as the created message, so a --json
  # run lets us assert the exact payload the command sent.
  defp echo_create do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces, 200}},
      {{"post", "/api/messages"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(Jason.decode!(raw))
       end}
    ])
  end

  describe "arb msg <recipient> <body>" do
    test "sends an info message to admiral by default" do
      echo_create()

      {out, _err, code} = capture(fn -> Msg.run(["admiral", "needs", "attention", "--json"]) end)
      assert code == 0
      sent = Jason.decode!(out)
      assert sent["to_ref"] == "admiral"
      assert sent["kind"] == "info"
      assert sent["body"] == "needs attention"
      assert sent["from_ref"] == "cli"
    end

    test "carries --kind, --subject and --directive" do
      echo_create()

      {out, _err, code} =
        capture(fn ->
          Msg.run([
            "admiral",
            "GitLab adapter complete",
            "--kind",
            "completion",
            "--subject",
            "bd-soren done",
            "--directive",
            "bd-soren",
            "--json"
          ])
        end)

      assert code == 0
      sent = Jason.decode!(out)
      assert sent["kind"] == "completion"
      assert sent["subject"] == "bd-soren done"
      assert sent["directive_ref"] == "bd-soren"
      assert sent["body"] == "GitLab adapter complete"
    end

    test "from identity comes from ARB_FROM when set" do
      System.put_env("ARB_FROM", "acolyte-019e")
      on_exit(fn -> System.delete_env("ARB_FROM") end)
      echo_create()

      {out, _err, code} = capture(fn -> Msg.run(["admiral", "done", "--json"]) end)
      assert code == 0
      assert Jason.decode!(out)["from_ref"] == "acolyte-019e"
    end

    test "human output confirms the send" do
      echo_create()
      {out, _err, code} = capture(fn -> Msg.run(["admiral", "needs", "attention"]) end)
      assert code == 0
      assert out =~ "Sent info to admiral."
    end

    test "rejects an invalid kind" do
      {_out, err, code} = capture(fn -> Msg.run(["admiral", "x", "--kind", "bogus"]) end)
      assert code != 0
      assert err =~ "invalid --kind"
    end

    test "requires a body" do
      {_out, err, code} = capture(fn -> Msg.run(["admiral"]) end)
      assert code != 0
      assert err =~ "requires a body"
    end

    test "requires a recipient" do
      {_out, err, code} = capture(fn -> Msg.run([]) end)
      assert code != 0
      assert err =~ "msg requires"
    end
  end
end
