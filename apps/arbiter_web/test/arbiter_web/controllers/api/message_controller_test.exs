defmodule ArbiterWeb.Api.MessageControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Messages.Message

  @ws "ws-api-msg"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/messages" do
    test "creates a mailbox message", %{conn: conn} do
      conn =
        post(conn, ~p"/api/messages", %{
          kind: "mailbox",
          from_ref: "admiral",
          to_ref: "bd-xyz",
          subject: "heads up",
          body: "check the API contract",
          workspace_id: @ws
        })

      body = json_response(conn, 201)
      assert body["kind"] == "mailbox"
      assert body["to_ref"] == "bd-xyz"
      assert body["body"] == "check the API contract"
      assert body["read_at"] == nil
    end

    test "returns 422 on missing workspace_id", %{conn: conn} do
      conn = post(conn, ~p"/api/messages", %{kind: "notification", body: "x"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 422 on invalid kind", %{conn: conn} do
      conn = post(conn, ~p"/api/messages", %{kind: "bogus", body: "x", workspace_id: @ws})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/messages" do
    test "lists messages, filtering by kind and to_ref", %{conn: conn} do
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "a notification"})
      {:ok, _} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-1", body: "for bd-1"})
      {:ok, _} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-2", body: "for bd-2"})

      conn = get(conn, ~p"/api/messages", %{kind: "notification"})
      data = json_response(conn, 200)["data"]
      assert Enum.all?(data, &(&1["kind"] == "notification"))

      conn = get(build_conn(), ~p"/api/messages", %{to_ref: "bd-1"})
      data = json_response(conn, 200)["data"]
      assert [%{"body" => "for bd-1"}] = data
    end

    test "unread=true returns only unacknowledged messages", %{conn: conn} do
      {:ok, m} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-u", body: "unread one"})
      {:ok, read} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-u", body: "read one"})
      {:ok, _} = Message.mark_read(read)

      conn = get(conn, ~p"/api/messages", %{to_ref: "bd-u", unread: "true"})
      data = json_response(conn, 200)["data"]
      assert [%{"id" => id}] = data
      assert id == m.id
    end

    test "rejects a bad limit", %{conn: conn} do
      conn = get(conn, ~p"/api/messages", %{limit: "abc"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "POST /api/messages/:id/read" do
    test "stamps read_at", %{conn: conn} do
      {:ok, m} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-r", body: "mark me"})

      conn = post(conn, ~p"/api/messages/#{m.id}/read", %{})
      body = json_response(conn, 200)
      refute is_nil(body["read_at"])
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = post(conn, ~p"/api/messages/00000000-0000-0000-0000-000000000000/read", %{})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
