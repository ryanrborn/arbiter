defmodule ArbiterWeb.MessagesLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "msg-ws-#{System.unique_integer([:positive])}", prefix: "mw"})

    {:ok, ws: ws}
  end

  describe "dashboard notifications panel" do
    test "renders the panel and existing notifications", %{conn: conn, ws: ws} do
      {:ok, _} =
        Message.notify(%{
          workspace_id: ws.id,
          from_ref: "bd-7",
          subject: "bd-7 complete",
          body: "done"
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Notifications"
      assert html =~ "bd-7 complete"
    end

    test "updates live when a new notification is broadcast", %{conn: conn, ws: ws} do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "freshly-arrived"

      # The LiveView subscribed to messages:<ws.id> on mount; creating a
      # notification broadcasts {:new_message, _} which the feed picks up.
      {:ok, _} = Message.notify(%{workspace_id: ws.id, subject: "freshly-arrived", body: "x"})

      assert render(view) =~ "freshly-arrived"
    end
  end

  describe "per-acolyte mailbox" do
    test "lists unread mailbox messages addressed to the task", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "mbx", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :flag,
          from_ref: "bd-varek",
          to_ref: task.id,
          body: "the API shape changed"
        })

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "Mailbox"
      assert html =~ "the API shape changed"
      assert html =~ "bd-varek"
    end

    test "compose form sends a direction to the task", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "compose", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      view
      |> form("#mailbox form", %{"body" => "check the API contract"})
      |> render_submit()

      assert render(view) =~ "the API contract"

      # The direction landed as a real mailbox-family message addressed to the task.
      assert [%Message{kind: :direction, from_ref: "admiral", body: "check the API contract"}] =
               Message.inbox(task.id, workspace_id: ws.id)
    end

    test "marking a message read removes it from the unread list", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "read", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, msg} =
        Message.send_mail(%{workspace_id: ws.id, to_ref: task.id, body: "ack me"})

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert render(view) =~ "ack me"

      view
      |> element(~s(button[phx-click="mark_read"][phx-value-id="#{msg.id}"]))
      |> render_click()

      refute render(view) =~ "ack me"
    end
  end

  describe "admiral mailbox panel" do
    test "renders unread mailbox-family mail addressed to the admiral", %{conn: conn, ws: ws} do
      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          from_ref: "bd-soren",
          to_ref: "admiral",
          subject: "needs a decision",
          body: "the device API contract is ambiguous",
          directive_ref: "bd-soren"
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Admiral Mailbox"
      assert html =~ "needs a decision"
      assert html =~ "the device API contract is ambiguous"
      assert html =~ "bd-soren"
      assert html =~ "escalation"
      # The stat-card count reflects the one unread item.
      assert html =~ "1 unread"
    end

    test "a plain :notification does NOT land in the admiral mailbox", %{conn: conn, ws: ws} do
      # Notifications are broadcast events, not addressed mail — they feed the
      # notifications panel, never the Admiral's actionable inbox.
      {:ok, _} =
        Message.notify(%{workspace_id: ws.id, subject: "just-an-fyi", body: "background hum"})

      {:ok, _view, html} = live(conn, "/")

      # Notification reaches the feed, but the Admiral mailbox stays empty.
      assert html =~ "just-an-fyi"
      assert html =~ "admiral-mailbox-empty"
      assert html =~ "0 unread"
      assert Message.inbox("admiral") == []
    end

    test "updates live when admiral mail is broadcast", %{conn: conn, ws: ws} do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "freshly-escalated"

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          to_ref: "admiral",
          subject: "freshly-escalated",
          body: "live arrival"
        })

      assert render(view) =~ "freshly-escalated"
    end

    test "marking a message read removes it from the unread list", %{conn: conn, ws: ws} do
      {:ok, msg} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :info,
          to_ref: "admiral",
          body: "ack-this-up"
        })

      {:ok, view, _html} = live(conn, "/")
      assert render(view) =~ "ack-this-up"

      view
      |> element(~s(#admiral-mailbox button[phx-click="mark_read"][phx-value-id="#{msg.id}"]))
      |> render_click()

      refute render(view) =~ "ack-this-up"
      # It's stamped read, not destroyed — still in the table, just not unread.
      assert {:ok, %Message{read_at: read_at}} = Ash.get(Message, msg.id)
      assert read_at
    end

    test "clear read drains the read tail but keeps unread mail", %{conn: conn, ws: ws} do
      {:ok, read_msg} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :info,
          to_ref: "admiral",
          body: "old-read"
        })

      {:ok, _} = Message.mark_read(read_msg)

      {:ok, unread_msg} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          to_ref: "admiral",
          body: "still-unread"
        })

      {:ok, view, html} = live(conn, "/")
      # The read one is not in the unread view; the unread one is.
      refute html =~ "old-read"
      assert html =~ "still-unread"

      view
      |> element(~s(button[phx-click="clear_admiral"]))
      |> render_click()

      # Read message destroyed; unread message untouched.
      assert {:error, _} = Ash.get(Message, read_msg.id)
      assert {:ok, %Message{}} = Ash.get(Message, unread_msg.id)
      assert render(view) =~ "still-unread"
    end
  end
end
