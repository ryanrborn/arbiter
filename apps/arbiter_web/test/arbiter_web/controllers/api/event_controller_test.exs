defmodule ArbiterWeb.Api.EventControllerTest do
  # async: false — the revocation-timing test mutates the module's
  # keepalive interval via Application env (same discipline as
  # `arbiter_web/test/arbiter_web/mcp/transport_test.exs`).
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "evt-ctrl-ws", prefix: "ec"})
    {:ok, ws: ws}
  end

  defp launch_session!(opts \\ []) do
    SessionEnv.sandbox("event-ctrl-#{System.unique_integer([:positive])}")
    SessionRunnerStub.reset()
    {:ok, session} = Sessions.launch(Keyword.merge([runner: SessionRunnerStub], opts))
    session
  end

  defp extend_keepalive(ms) do
    previous = Application.get_env(:arbiter_web, ArbiterWeb.Api.EventController, [])
    Application.put_env(:arbiter_web, ArbiterWeb.Api.EventController, keepalive_ms: ms)
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Api.EventController, previous) end)
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

    test "returns 401 for a worker-tier token (only coordinator allowed)", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "t", workspace_id: ws.id})
      token = Scope.mint_worker(task, "test-repo")
      conn = get(conn, "/events?token=#{token}")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  # ---- header auth (bd-aqafdr) ---------------------------------------------
  # A session's own token lives only in a mode-0600 curl config
  # (`Arbiter.Sessions.Provisioning`), never in argv, so its monitor sends it
  # as a header rather than a query param. `token=` must keep working
  # unchanged for the `arb init` runbook's `curl -N` loop.

  describe "GET /events — header auth" do
    test "a coordinator token as Authorization: Bearer enters the stream", %{ws: ws} do
      token = Scope.mint_coordinator(ws.id)

      task =
        Task.async(fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
          |> get("/events")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
    end

    test "a session token as Authorization: Bearer enters the stream" do
      session = launch_session!()
      token = Sessions.mint_mcp_token(session)

      task =
        Task.async(fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
          |> get("/events")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
    end

    test "returns 401 for a revoked session token presented as a header", %{conn: conn} do
      session = launch_session!()
      token = Sessions.mint_mcp_token(session)
      {:ok, _} = Sessions.revoke_mcp_token(session)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get("/events")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "malformed Authorization header falls back to query token", %{ws: ws} do
      token = Scope.mint_coordinator(ws.id)

      task =
        Task.async(fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Basic garbage")
          |> get("/events?token=#{token}")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
    end
  end

  # ---- revocation mid-stream (bd-aqafdr) -----------------------------------

  describe "GET /events — revocation closes an open stream" do
    test "a stream open on a session token closes within one keepalive tick after revocation" do
      extend_keepalive(50)
      session = launch_session!()
      token = Sessions.mint_mcp_token(session)

      task = Task.async(fn -> get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}") end)
      assert nil == Task.yield(task, 100)

      {:ok, _} = Sessions.revoke_mcp_token(session)

      assert {:ok, _conn} = Task.yield(task, 500),
             "expected the stream to close once the keepalive tick re-checks revocation"
    end

    test "a busy stream (events faster than keepalive) still closes after revocation" do
      extend_keepalive(20)
      session = launch_session!()
      token = Sessions.mint_mcp_token(session)

      task = Task.async(fn -> get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}") end)
      assert nil == Task.yield(task, 50)

      pump =
        Task.async(fn ->
          for _ <- 1..50 do
            Phoenix.PubSub.broadcast(
              Arbiter.PubSub,
              "events",
              {:event, %{topic: "worker_done", at: DateTime.to_iso8601(DateTime.utc_now())}}
            )

            Process.sleep(5)
          end
        end)

      Process.sleep(50)
      {:ok, _} = Sessions.revoke_mcp_token(session)

      assert {:ok, _conn} = Task.yield(task, 500),
             "expected a stream with continuous event traffic to still close after revocation" <>
               " — revocation must be checked on a timer, not only on receive idle timeout"

      Task.shutdown(pump, :brutal_kill)
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

  # ---- since= validation ---------------------------------------------------

  describe "GET /events — since validation" do
    setup %{ws: ws} do
      {:ok, token: Scope.mint_coordinator(ws.id)}
    end

    test "returns 400 for a since value that is neither an integer cursor nor an ISO-8601 timestamp",
         %{conn: conn, token: token} do
      conn = get(conn, "/events?token=#{token}&since=not-a-cursor")
      body = json_response(conn, 400)
      assert body["error"] =~ "invalid since"
    end

    test "enters the stream for a valid integer cursor", %{token: token} do
      task =
        Task.async(fn ->
          get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}&since=0")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
    end

    test "enters the stream for a valid ISO-8601 timestamp", %{token: token} do
      since = DateTime.utc_now() |> DateTime.to_iso8601() |> URI.encode_www_form()

      task =
        Task.async(fn ->
          get(Phoenix.ConnTest.build_conn(), "/events?token=#{token}&since=#{since}")
        end)

      assert nil == Task.yield(task, 100)
      Task.shutdown(task, :brutal_kill)
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

  # ---- replay -> live watermark stitching ----------------------------------
  # The delivery decision is the only genuinely novel logic in this
  # controller (replay/3 itself is tested at the domain level in
  # events_test.exs). Exercised directly via the pure `deliver?/3` helper
  # rather than through the receive loop, since the loop isn't independently
  # drivable outside a live connection.

  describe "ArbiterWeb.Api.EventController.deliver?/3" do
    alias ArbiterWeb.Api.EventController

    test "cursor at or below the watermark is not delivered (already replayed)" do
      topics = MapSet.new(["worker_done"])
      refute EventController.deliver?(%{topic: "worker_done", cursor: 5}, topics, 5)
      refute EventController.deliver?(%{topic: "worker_done", cursor: 3}, topics, 5)
    end

    test "cursor above the watermark is delivered" do
      topics = MapSet.new(["worker_done"])
      assert EventController.deliver?(%{topic: "worker_done", cursor: 6}, topics, 5)
    end

    test "an out-of-order live arrival above the watermark is still delivered — regression for the frozen-watermark fix" do
      # Two concurrent broadcasters can persist seq=10 then seq=11 but have
      # their PubSub sends land out of order. The watermark must stay frozen
      # at the replay high-water mark (not advance on every live send), or
      # the lower-cursor event arriving after the higher one is wrongly
      # treated as already-delivered.
      topics = MapSet.new(["worker_done"])
      watermark = 9

      assert EventController.deliver?(%{topic: "worker_done", cursor: 11}, topics, watermark)
      # watermark is NOT advanced to 11 here — it stays at the replay
      # watermark for the life of the connection.
      assert EventController.deliver?(%{topic: "worker_done", cursor: 10}, topics, watermark)
    end

    test "watermark clamped to the log's high-water mark when replay is empty — regression for the since=-ahead-of-DB fix" do
      # A since= cursor past the end of the table degrades to "stream
      # everything live" (watermark clamped to the actual max seq) rather
      # than silently dropping every future live event.
      topics = MapSet.new(["worker_done"])
      clamped_watermark = 42

      assert EventController.deliver?(
               %{topic: "worker_done", cursor: 43},
               topics,
               clamped_watermark
             )

      refute EventController.deliver?(
               %{topic: "worker_done", cursor: 42},
               topics,
               clamped_watermark
             )
    end

    test "an event with no cursor is always delivered" do
      topics = MapSet.new(["worker_done"])
      assert EventController.deliver?(%{topic: "worker_done"}, topics, 100)
    end

    test "an event on an unsubscribed topic is never delivered" do
      topics = MapSet.new(["worker_done"])
      refute EventController.deliver?(%{topic: "inbox", cursor: 1}, topics, nil)
    end

    test "nil watermark (nothing replayed) delivers everything" do
      topics = MapSet.new(["worker_done"])
      assert EventController.deliver?(%{topic: "worker_done", cursor: 1}, topics, nil)
    end
  end

  # ---- events module unit tests -------------------------------------------

  describe "Arbiter.Events" do
    test "valid_topics/0 returns the expected topic list" do
      topics = Arbiter.Events.valid_topics()
      assert "inbox" in topics
      assert "review_gate" in topics
      assert "worker_failed" in topics
      assert "worker_done" in topics
      assert "task_state" in topics
    end

    test "broadcast/3 returns :ok and fires on the PubSub topic", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      assert :ok = Arbiter.Events.broadcast(ws.id, "worker_done", %{task_id: "bd-test"})

      assert_receive {:event, event}, 500
      assert event.topic == "worker_done"
      assert event.task_id == "bd-test"
      assert is_binary(event.at)
    end

    test "broadcast/3 returns :ok silently when workspace_id is nil" do
      assert :ok = Arbiter.Events.broadcast(nil, "worker_done", %{task_id: "bd-x"})
    end

    test "broadcast/3 scopes events to the workspace — other workspaces don't receive them",
         %{ws: ws} do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws", prefix: "ow"})

      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      # Broadcast on the OTHER workspace
      Arbiter.Events.broadcast(other_ws.id, "worker_done", %{task_id: "bd-other"})

      # Should NOT receive this event on ws's topic
      refute_receive {:event, %{task_id: "bd-other"}}, 100
    end
  end
end
