defmodule ArbiterCli.Cmd.InboxTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Inbox

  defp admiral_msg(attrs) do
    Map.merge(
      %{
        "id" => "0b9d1f2a-1111-2222-3333-444455556666",
        "kind" => "completion",
        "from_ref" => "acolyte-019e",
        "to_ref" => "admiral",
        "directive_ref" => "bd-1qx1nt",
        "subject" => "GitLab adapter complete",
        "body" => "All tests green.",
        "inserted_at" => "2026-05-28T12:00:00.000000Z"
      },
      attrs
    )
  end

  describe "arb inbox (admiral, unread)" do
    test "lists unread admiral mail in the directive/kind/from format" do
      stub_get("/api/messages", %{"data" => [admiral_msg(%{})]}, 200)

      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "Coordinator inbox — 1 unread"
      assert out =~ "[bd-1qx1nt]"
      assert out =~ "completion"
      assert out =~ "from acolyte-019e"
      assert out =~ "GitLab adapter complete"
      # The leading token is the short message id handle.
      assert out =~ "0b9d1f2a"
    end

    test "does NOT mark messages read (triage is deliberate)" do
      # Only the GET is stubbed. If the command tried to POST a read,
      # the stub would 500 and the body assertion below would fail.
      stub_get("/api/messages", %{"data" => [admiral_msg(%{})]}, 200)
      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "GitLab adapter complete"
    end

    test "prints a friendly message when empty" do
      stub_get("/api/messages", %{"data" => []}, 200)
      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "coordinator inbox empty"
    end

    test "--json emits the raw message array" do
      stub_get("/api/messages", %{"data" => [admiral_msg(%{})]}, 200)
      {out, _err, code} = capture(fn -> Inbox.run(["--json"]) end)
      assert code == 0
      assert {:ok, %{"data" => [%{"to_ref" => "admiral"}]}} = Jason.decode(out)
    end
  end

  describe "arb inbox --all" do
    test "lists recent read + unread" do
      stub_get(
        "/api/messages",
        %{"data" => [admiral_msg(%{"read_at" => "2026-05-28T12:30:00.000000Z"})]},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run(["--all"]) end)
      assert code == 0
      assert out =~ "Coordinator inbox — 1 recent"
    end
  end

  describe "arb inbox read <id>" do
    test "marks one read by full id and shows the full body" do
      id = "11111111-2222-3333-4444-555566667777"

      stub_routes([
        {{"post", "/api/messages/#{id}/read"},
         {admiral_msg(%{"id" => id, "body" => "Full body text here."}), 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["read", id]) end)
      assert code == 0
      assert out =~ "Full body text here."
      assert out =~ "Issue:"
      assert out =~ "bd-1qx1nt"
    end

    test "resolves a short id prefix against admiral mail, then reads it" do
      full = "0b9d1f2a-1111-2222-3333-444455556666"

      stub_routes([
        {{"get", "/api/messages"}, {%{"data" => [admiral_msg(%{"id" => full})]}, 200}},
        {{"post", "/api/messages/#{full}/read"},
         {admiral_msg(%{"id" => full, "body" => "Resolved by prefix."}), 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["read", "0b9d1f2a"]) end)
      assert code == 0
      assert out =~ "Resolved by prefix."
    end

    test "errors with no id" do
      {_out, err, code} = capture(fn -> Inbox.run(["read"]) end)
      assert code != 0
      assert err =~ "requires a message id"
    end
  end

  describe "arb inbox clear" do
    test "reports how many read messages were destroyed (no unread)" do
      stub_delete(
        "/api/messages",
        %{"data" => %{"deleted_read" => 3, "deleted_unread" => 0, "remaining_unread" => 0}},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run(["clear"]) end)
      assert code == 0
      assert out =~ "Cleared 3 read messages."
    end

    test "reports read messages cleared and unread remaining when unread exists" do
      stub_delete(
        "/api/messages",
        %{"data" => %{"deleted_read" => 2, "deleted_unread" => 0, "remaining_unread" => 4}},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run(["clear"]) end)
      assert code == 0
      assert out =~ "Cleared 2 read messages"
      assert out =~ "4 unread messages remain"
      assert out =~ "clear --all"
    end

    test "says inbox is empty when nothing to clear" do
      stub_delete(
        "/api/messages",
        %{"data" => %{"deleted_read" => 0, "deleted_unread" => 0, "remaining_unread" => 0}},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run(["clear"]) end)
      assert code == 0
      assert out =~ "Nothing to clear (inbox is empty)"
    end

    test "clears all messages with --all flag" do
      stub_delete(
        "/api/messages",
        %{"data" => %{"deleted_read" => 2, "deleted_unread" => 4, "remaining_unread" => 0}},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run(["clear", "--all"]) end)
      assert code == 0
      assert out =~ "Cleared 2 read + 4 unread messages (6 total)"
    end
  end

  describe "arb inbox <task-id> (worker path)" do
    test "lists a task's unread mail and marks each read" do
      stub_routes([
        {{"get", "/api/messages"},
         {%{
            "data" => [
              %{
                "id" => "m-1",
                "kind" => "direction",
                "from_ref" => "admiral",
                "to_ref" => "bd-1",
                "body" => "check the API contract"
              }
            ]
          }, 200}},
        {{"post", "/api/messages/m-1/read"}, {%{"id" => "m-1"}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["bd-1"]) end)
      assert code == 0
      assert out =~ "Unread mail for bd-1 (1)"
      assert out =~ "check the API contract"
    end

    test "filters out notifications (never mail)" do
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

      {out, _err, code} = capture(fn -> Inbox.run(["bd-1"]) end)
      assert code == 0
      assert out =~ "real mail"
      refute out =~ "noise"
    end
  end
end
