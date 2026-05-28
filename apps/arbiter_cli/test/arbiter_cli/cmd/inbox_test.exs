defmodule ArbiterCli.Cmd.InboxTest do
  use ArbiterCli.CliCase, async: false

  describe "arb inbox <bead-id>" do
    test "lists unread mail and marks each read" do
      stub_routes([
        {{"get", "/api/messages"},
         {%{
            "data" => [
              %{
                "id" => "m-1",
                "kind" => "direction",
                "from_ref" => "admiral",
                "to_ref" => "bd-1",
                "subject" => "heads up",
                "body" => "check the API contract"
              }
            ]
          }, 200}},
        {{"post", "/api/messages/m-1/read"}, {%{"id" => "m-1"}, 200}}
      ])

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Inbox.run(["bd-1"]) end)
      assert code == 0
      assert out =~ "Unread mail (1)"
      assert out =~ "[direction] from admiral"
      assert out =~ "check the API contract"
    end

    test "prints a friendly message when empty" do
      stub_get("/api/messages", %{"data" => []}, 200)
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Inbox.run(["bd-1"]) end)
      assert code == 0
      assert out =~ "(no unread mail)"
    end

    test "filters out notifications (they are never mail)" do
      stub_routes([
        {{"get", "/api/messages"},
         {%{
            "data" => [
              %{"id" => "n-1", "kind" => "notification", "body" => "noise"},
              %{"id" => "m-1", "kind" => "mailbox", "from_ref" => "bd-2", "body" => "real mail"}
            ]
          }, 200}},
        {{"post", "/api/messages/m-1/read"}, {%{"id" => "m-1"}, 200}}
      ])

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Inbox.run([]) end)
      assert code == 0
      assert out =~ "Unread mail (1)"
      assert out =~ "real mail"
      refute out =~ "noise"
    end

    test "--json emits JSON" do
      stub_routes([
        {{"get", "/api/messages"},
         {%{"data" => [%{"id" => "m-1", "kind" => "flag", "body" => "x"}]}, 200}},
        {{"post", "/api/messages/m-1/read"}, {%{"id" => "m-1"}, 200}}
      ])

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Inbox.run(["--json"]) end)
      assert code == 0
      assert {:ok, %{"data" => [%{"id" => "m-1"}]}} = Jason.decode(out)
    end
  end
end
