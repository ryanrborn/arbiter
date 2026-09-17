defmodule ArbiterCli.Cmd.InboxTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Inbox

  defp coordinator_msg(attrs) do
    Map.merge(
      %{
        "id" => "0b9d1f2a-1111-2222-3333-444455556666",
        "kind" => "completion",
        "from_ref" => "worker-019e",
        "to_ref" => "coordinator",
        "directive_ref" => "bd-1qx1nt",
        "subject" => "GitLab adapter complete",
        "body" => "All tests green.",
        "inserted_at" => "2026-05-28T12:00:00.000000Z"
      },
      attrs
    )
  end

  describe "arb inbox (coordinator, unread)" do
    test "lists unread coordinator mail in the directive/kind/from format" do
      stub_get("/api/messages", %{"data" => [coordinator_msg(%{})]}, 200)

      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "Coordinator inbox — 1 unread"
      assert out =~ "[bd-1qx1nt]"
      assert out =~ "completion"
      assert out =~ "from worker-019e"
      assert out =~ "GitLab adapter complete"
      # The leading token is the short message id handle.
      assert out =~ "0b9d1f2a"
    end

    test "prefers task_ref over the legacy directive_ref when both are present" do
      stub_get(
        "/api/messages",
        %{
          "data" => [
            coordinator_msg(%{"task_ref" => "bd-canonical", "directive_ref" => "bd-legacy"})
          ]
        },
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "[bd-canonical]"
      refute out =~ "bd-legacy"
    end

    test "falls back to task_ref alone when directive_ref is absent" do
      stub_get(
        "/api/messages",
        %{"data" => [coordinator_msg(%{"task_ref" => "bd-canonical", "directive_ref" => nil})]},
        200
      )

      {out, _err, code} = capture(fn -> Inbox.run([]) end)
      assert code == 0
      assert out =~ "[bd-canonical]"
    end

    test "does NOT mark messages read (triage is deliberate)" do
      # Only the GET is stubbed. If the command tried to POST a read,
      # the stub would 500 and the body assertion below would fail.
      stub_get("/api/messages", %{"data" => [coordinator_msg(%{})]}, 200)
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
      stub_get("/api/messages", %{"data" => [coordinator_msg(%{})]}, 200)
      {out, _err, code} = capture(fn -> Inbox.run(["--json"]) end)
      assert code == 0
      assert {:ok, %{"data" => [%{"to_ref" => "coordinator"}]}} = Jason.decode(out)
    end
  end

  describe "arb inbox --all" do
    test "lists recent read + unread" do
      stub_get(
        "/api/messages",
        %{"data" => [coordinator_msg(%{"read_at" => "2026-05-28T12:30:00.000000Z"})]},
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
         {coordinator_msg(%{"id" => id, "body" => "Full body text here."}), 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["read", id]) end)
      assert code == 0
      assert out =~ "Full body text here."
      assert out =~ "Issue:"
      assert out =~ "bd-1qx1nt"
    end

    test "resolves a short id prefix against coordinator mail, then reads it" do
      full = "0b9d1f2a-1111-2222-3333-444455556666"

      stub_routes([
        {{"get", "/api/messages"}, {%{"data" => [coordinator_msg(%{"id" => full})]}, 200}},
        {{"post", "/api/messages/#{full}/read"},
         {coordinator_msg(%{"id" => full, "body" => "Resolved by prefix."}), 200}}
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

  describe "arb inbox clear <id|prefix> [...]" do
    test "clears one message given a full id" do
      id = "11111111-2222-3333-4444-555566667777"

      stub_routes([
        {{"delete", "/api/messages"}, {%{"data" => %{"cleared" => [id], "not_found" => []}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", id]) end)
      assert code == 0
      assert out =~ "Cleared 1 message."
    end

    test "resolves a unique short prefix against coordinator mail, then clears it" do
      full = "0b9d1f2a-1111-2222-3333-444455556666"

      stub_routes([
        {{"get", "/api/messages"}, {%{"data" => [coordinator_msg(%{"id" => full})]}, 200}},
        {{"delete", "/api/messages"},
         {%{"data" => %{"cleared" => [full], "not_found" => []}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", "0b9d1f2a"]) end)
      assert code == 0
      assert out =~ "Cleared 1 message."
    end

    test "clears several ids in one call" do
      id1 = "11111111-2222-3333-4444-555566667777"
      id2 = "22222222-3333-4444-5555-666677778888"

      stub_routes([
        {{"delete", "/api/messages"},
         {%{"data" => %{"cleared" => [id1, id2], "not_found" => []}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", id1, id2]) end)
      assert code == 0
      assert out =~ "Cleared 2 messages."
    end

    test "refuses an ambiguous prefix and lists the candidates" do
      stub_routes([
        {{"get", "/api/messages"},
         {%{
            "data" => [
              coordinator_msg(%{"id" => "0b9d1f2a-1111-2222-3333-444455556666"}),
              coordinator_msg(%{"id" => "0b9d9999-1111-2222-3333-444455556666"})
            ]
          }, 200}}
      ])

      {_out, err, code} = capture(fn -> Inbox.run(["clear", "0b9d"]) end)
      assert code != 0
      assert err =~ "ambiguous id prefix"
      assert err =~ "0b9d1f2a-1111-2222-3333-444455556666"
      assert err =~ "0b9d9999-1111-2222-3333-444455556666"
    end

    test "errors clearly on an unknown id" do
      stub_routes([
        {{"get", "/api/messages"}, {%{"data" => []}, 200}}
      ])

      {_out, err, code} = capture(fn -> Inbox.run(["clear", "deadbeef"]) end)
      assert code != 0
      assert err =~ "no coordinator message matches"
    end

    test "reports any ids the server didn't find" do
      id = "11111111-2222-3333-4444-555566667777"

      stub_routes([
        {{"delete", "/api/messages"}, {%{"data" => %{"cleared" => [], "not_found" => [id]}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", id]) end)
      assert code == 0
      assert out =~ "Cleared 0 messages"
      assert out =~ "1 id not found"
      assert out =~ id
    end

    test "--json emits cleared and not_found" do
      id = "11111111-2222-3333-4444-555566667777"

      stub_routes([
        {{"delete", "/api/messages"}, {%{"data" => %{"cleared" => [id], "not_found" => []}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", id, "--json"]) end)
      assert code == 0
      assert {:ok, %{"data" => %{"cleared" => [^id], "not_found" => []}}} = Jason.decode(out)
    end
  end

  describe "arb inbox clear --task <task-id>" do
    test "clears every coordinator message for the task" do
      stub_routes([
        {{"delete", "/api/messages"},
         {%{"data" => %{"cleared" => ["m-1", "m-2"], "cleared_count" => 2}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", "--task", "bd-1qx1nt"]) end)
      assert code == 0
      assert out =~ "Cleared 2 messages for bd-1qx1nt."
    end

    test "reports nothing to clear" do
      stub_routes([
        {{"delete", "/api/messages"},
         {%{"data" => %{"cleared" => [], "cleared_count" => 0}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", "--task", "bd-1qx1nt"]) end)
      assert code == 0
      assert out =~ "Nothing to clear for bd-1qx1nt."
    end

    test "requires a task id" do
      {_out, err, code} = capture(fn -> Inbox.run(["clear", "--task"]) end)
      assert code != 0
      assert err =~ "requires a task id"
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
                "from_ref" => "coordinator",
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

  # ---- bd-8akewg: explicit reader ------------------------------------------

  describe "arb inbox --session <id>" do
    test "forwards the session as the reader on the unread listing" do
      stub_routes([
        {{"get", "/api/messages"},
         fn conn ->
           assert conn.query_string =~ "session=sess-42"
           assert conn.query_string =~ "unread=true"

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => [coordinator_msg(%{})]})
         end}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["--session", "sess-42"]) end)
      assert code == 0
      assert out =~ "Coordinator inbox — 1 unread"
    end

    test "forwards the session on clear" do
      stub_routes([
        {{"delete", "/api/messages"},
         fn conn ->
           assert conn.query_string =~ "session=sess-42"

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "deleted_read" => 1,
               "deleted_unread" => 0,
               "remaining_unread" => 0
             }
           })
         end}
      ])

      {_out, _err, code} = capture(fn -> Inbox.run(["clear", "--session", "sess-42"]) end)
      assert code == 0
    end

    test "forwards the session on clear <id>" do
      id = "0b9d1f2a-1111-2222-3333-444455556666"

      stub_routes([
        {{"delete", "/api/messages"},
         fn conn ->
           assert conn.query_string =~ "session=sess-42"
           assert conn.query_string =~ "ids="

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => %{"cleared" => [id], "not_found" => []}})
         end}
      ])

      {out, _err, code} = capture(fn -> Inbox.run(["clear", id, "--session", "sess-42"]) end)
      assert code == 0
      assert out =~ "Cleared 1 message."
    end

    test "forwards the session on clear --task" do
      stub_routes([
        {{"delete", "/api/messages"},
         fn conn ->
           assert conn.query_string =~ "session=sess-42"
           assert conn.query_string =~ "task_id=bd-abc123"

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"data" => %{"cleared" => ["x"], "cleared_count" => 1}})
         end}
      ])

      {out, _err, code} =
        capture(fn -> Inbox.run(["clear", "--task", "bd-abc123", "--session", "sess-42"]) end)

      assert code == 0
      assert out =~ "Cleared 1 message for bd-abc123."
    end

    test "forwards the session on read <id>" do
      id = "0b9d1f2a-1111-2222-3333-444455556666"

      stub_routes([
        {{"post", "/api/messages/#{id}/read"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert body =~ "sess-42"

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(coordinator_msg(%{}))
         end}
      ])

      {_out, _err, code} =
        capture(fn -> Inbox.run(["read", id, "--session", "sess-42"]) end)

      assert code == 0
    end
  end
end
