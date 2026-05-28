defmodule ArbiterWeb.MessagesLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
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
    test "lists unread mailbox messages addressed to the bead", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "mbx", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r", workspace_id: ws.id)

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :flag,
          from_ref: "bd-varek",
          to_ref: bead.id,
          body: "the API shape changed"
        })

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ "Mailbox"
      assert html =~ "the API shape changed"
      assert html =~ "bd-varek"
    end

    test "compose form sends a direction to the bead", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "compose", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, ~p"/polecats/#{bead.id}")

      view
      |> form("#mailbox form", %{"body" => "check the API contract"})
      |> render_submit()

      assert render(view) =~ "the API contract"

      # The direction landed as a real mailbox-family message addressed to the bead.
      assert [%Message{kind: :direction, from_ref: "admiral", body: "check the API contract"}] =
               Message.inbox(bead.id, workspace_id: ws.id)
    end

    test "marking a message read removes it from the unread list", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "read", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r", workspace_id: ws.id)

      {:ok, msg} =
        Message.send_mail(%{workspace_id: ws.id, to_ref: bead.id, body: "ack me"})

      {:ok, view, _html} = live(conn, ~p"/polecats/#{bead.id}")
      assert render(view) =~ "ack me"

      view
      |> element(~s(button[phx-click="mark_read"][phx-value-id="#{msg.id}"]))
      |> render_click()

      refute render(view) =~ "ack me"
    end
  end
end
