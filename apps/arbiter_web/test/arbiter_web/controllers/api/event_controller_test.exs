defmodule ArbiterWeb.Api.EventControllerTest do
  use ArbiterWeb.ConnCase, async: true

  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP.Scope

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "evt-ctrl-ws", prefix: "ec"})
    {:ok, ws: ws}
  end

  # ---- auth ---------------------------------------------------------------

  describe "GET /events — auth" do
    test "returns 401 when token is missing", %{conn: conn} do
      conn = get(conn, "/events")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 401 when token is blank", %{conn: conn} do
      conn = get(conn, "/events?token=")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 401 when token is invalid", %{conn: conn} do
      conn = get(conn, "/events?token=not-a-real-token")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 401 for a polecat-tier token (only coordinator allowed)", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Arbiter.Beads.Issue, %{title: "t", workspace_id: ws.id})
      token = Scope.mint_polecat(bead, "test-rig")
      conn = get(conn, "/events?token=#{token}")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  # ---- topic parsing -------------------------------------------------------

  describe "GET /events — topic validation" do
    setup %{ws: ws} do
      {:ok, token: Scope.mint_coordinator(ws.id)}
    end

    test "returns 400 for an unknown topic name", %{conn: conn, token: token} do
      conn = get(conn, "/events?token=#{token}&subscribe=inbox,notarealthing")
      body = json_response(conn, 400)
      assert body["error"] =~ "unknown topics"
      assert body["error"] =~ "notarealthing"
    end

    test "returns 400 when all topics are unknown", %{conn: conn, token: token} do
      conn = get(conn, "/events?token=#{token}&subscribe=foo,bar")
      body = json_response(conn, 400)
      assert body["error"] =~ "unknown topics"
    end

    test "returns 400 for a mixed valid/invalid subscribe list", %{conn: conn, token: token} do
      conn = get(conn, "/events?token=#{token}&subscribe=inbox,INVALID")
      body = json_response(conn, 400)
      assert body["error"] =~ "INVALID"
    end
  end

  # ---- streaming happy path -----------------------------------------------
  # Testing an infinite chunked stream synchronously is impractical in
  # Phoenix.ConnTest (get/2 blocks until the handler returns, which it never
  # does for a long-lived stream). We verify the happy path via:
  #   1. A Task-based test that confirms the endpoint does NOT return 401/400
  #      with a valid token+topics (task stays blocked → no error response).
  #   2. Manual end-to-end verification with `curl -N` (see acceptance criteria).

  describe "GET /events — streaming" do
    setup %{ws: ws} do
      {:ok, token: Scope.mint_coordinator(ws.id)}
    end

    test "enters the stream (does not return an error) for a valid coordinator token",
         %{token: token} do
      # Task.yield returns nil when the task hasn't finished yet. A task that
      # immediately returned a 401/400 would finish in microseconds; a task
      # blocked in the receive loop won't finish. This proves we reached the
      # stream, not an error exit.
      task = Task.async(fn -> get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}") end)
      result = Task.yield(task, 100)
      assert result == nil, "expected the stream to be running, not an immediate error response"
      Task.shutdown(task, :brutal_kill)
    end

    test "enters the stream with default topics when subscribe is omitted", %{token: token} do
      task =
        Task.async(fn ->
          get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
    end

    test "enters the stream for all valid topic combinations", %{token: token} do
      for topic <- Arbiter.Events.valid_topics() do
        task =
          Task.async(fn ->
            get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}&subscribe=#{topic}")
          end)

        assert nil == Task.yield(task, 100), "topic #{topic} should start streaming"
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  # ---- events module unit tests -------------------------------------------

  describe "Arbiter.Events" do
    test "valid_topics/0 returns the expected topic list" do
      topics = Arbiter.Events.valid_topics()
      assert "inbox" in topics
      assert "review_gate" in topics
      assert "polecat_failed" in topics
      assert "polecat_done" in topics
      assert "bead_state" in topics
    end

    test "broadcast/3 returns :ok and fires on the PubSub topic", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      assert :ok = Arbiter.Events.broadcast(ws.id, "polecat_done", %{bead_id: "bd-test"})

      assert_receive {:event, event}, 500
      assert event.topic == "polecat_done"
      assert event.bead_id == "bd-test"
      assert is_binary(event.at)
    end

    test "broadcast/3 returns :ok silently when workspace_id is nil" do
      assert :ok = Arbiter.Events.broadcast(nil, "polecat_done", %{bead_id: "bd-x"})
    end

    test "broadcast/3 scopes events to the workspace — other workspaces don't receive them",
         %{ws: ws} do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws", prefix: "ow"})

      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      # Broadcast on the OTHER workspace
      Arbiter.Events.broadcast(other_ws.id, "polecat_done", %{bead_id: "bd-other"})

      # Should NOT receive this event on ws's topic
      refute_receive {:event, %{bead_id: "bd-other"}}, 100
    end
  end
end
