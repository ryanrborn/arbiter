defmodule ArbiterWeb.MCP.SseTransportTest do
  @moduledoc """
  End-to-end coverage for the deprecated HTTP+SSE (2024-11-05) transport that
  `ArbiterWeb.MCP.Plug` serves alongside Streamable HTTP: the `endpoint` event
  must advertise a routable session id, and a POST carrying that id must be
  acknowledged with `202` while its JSON-RPC reply is written to the stream.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.MCP.Session

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-sse-ws", prefix: "mcpsse"})

    {:ok, conn: conn, ws: ws, token: Scope.mint_coordinator(ws.id)}
  end

  describe "endpoint event" do
    test "advertises a sessionId that matches the stream's Mcp-Session-Id", ctx do
      conn = sse_get(ctx.conn, ctx.token)

      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert uri = advertised_endpoint(conn.resp_body)
      assert URI.decode_query(URI.parse(uri).query || "")["sessionId"] == session_id
    end

    test "keeps the token query parameter when the stream authenticated by query", ctx do
      conn =
        ctx.conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/mcp?token=#{URI.encode_www_form(ctx.token)}")

      assert uri = advertised_endpoint(conn.resp_body)
      query = URI.decode_query(URI.parse(uri).query || "")
      assert query["token"] == ctx.token
      assert query["sessionId"] != nil
    end
  end

  describe "HTTP+SSE handshake, end to end" do
    test "initialize and tools/list are 202-acked and replied to on the stream", ctx do
      extend_sse_lifetime(15_000)

      session_id = "sse-flow-" <> Session.new_id()
      {task, stream_pid} = open_stream(ctx.token, session_id)

      init =
        post_via_session(
          ctx.token,
          session_id,
          rpc("initialize", %{"protocolVersion" => "2024-11-05"}, 1)
        )

      assert init.status == 202
      assert init.resp_body == ""

      list = post_via_session(ctx.token, session_id, rpc("tools/list", %{}, 2))
      assert list.status == 202
      assert list.resp_body == ""

      send(stream_pid, :mcp_sse_close)
      stream = Task.await(task, 10_000)

      assert [initialize_reply, list_reply] = message_events(stream.resp_body)

      assert initialize_reply["id"] == 1
      assert initialize_reply["result"]["protocolVersion"] == "2024-11-05"
      assert initialize_reply["result"]["serverInfo"]["name"] == "arbiter"

      assert list_reply["id"] == 2
      names = Enum.map(list_reply["result"]["tools"], & &1["name"])
      assert "task_ready" in names
    end

    test "a notification routed by session id is 202-acked and writes nothing", ctx do
      extend_sse_lifetime(15_000)

      session_id = "sse-notif-" <> Session.new_id()
      {task, stream_pid} = open_stream(ctx.token, session_id)

      ack =
        post_via_session(ctx.token, session_id, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert ack.status == 202

      send(stream_pid, :mcp_sse_close)
      stream = Task.await(task, 10_000)

      assert message_events(stream.resp_body) == []
    end

    test "a sessionId with no open stream is 404, not a silent inline reply", ctx do
      conn = post_via_session(ctx.token, "no-such-session-#{Session.new_id()}", rpc("ping"))

      assert json_response(conn, 404)["error"]["type"] == "no_session"
    end
  end

  describe "Streamable HTTP is unaffected" do
    test "a POST with no sessionId still answers inline", ctx do
      conn =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.token}")
        |> post("/mcp", Jason.encode!(rpc("initialize", %{"protocolVersion" => "2025-06-18"})))

      assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-06-18"
    end
  end

  describe "OAuth discovery probes" do
    test "/.well-known/oauth-protected-resource is 404", ctx do
      assert not_found?(ctx.conn, "/.well-known/oauth-protected-resource")
    end

    test "/.well-known/oauth-protected-resource/mcp is 404", ctx do
      assert not_found?(ctx.conn, "/.well-known/oauth-protected-resource/mcp")
    end
  end

  # ---- helpers -------------------------------------------------------------

  # A 404 tells an MCP client "no OAuth here, use the configured token". Routing
  # these into the MCP plug would answer 405 and strand the client in the OAuth
  # branch, so assert the absence of a route however the endpoint renders it.
  defp not_found?(conn, path) do
    try do
      get(conn, path).status == 404
    rescue
      Phoenix.Router.NoRouteError -> true
    end
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp sse_get(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "text/event-stream")
    |> get("/mcp")
  end

  defp post_via_session(token, session_id, request) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/mcp?sessionId=#{URI.encode_www_form(session_id)}", Jason.encode!(request))
  end

  # The SSE handler blocks its process for the stream's lifetime, so it runs in a
  # Task while the test process drives the POST side. The default test lifetime
  # is 0 (stream closes immediately); stretch it for the duration of one test.
  defp extend_sse_lifetime(ms) do
    previous = Application.get_env(:arbiter, Arbiter.MCP, [])

    Application.put_env(
      :arbiter,
      Arbiter.MCP,
      Keyword.merge(previous, sse_max_lifetime_ms: ms, sse_keepalive_ms: 100)
    )

    on_exit(fn -> Application.put_env(:arbiter, Arbiter.MCP, previous) end)
  end

  defp open_stream(token, session_id) do
    task = Task.async(fn -> sse_get(build_conn(), token, session_id) end)
    {task, await_stream_pid(session_id, 300)}
  end

  defp sse_get(conn, token, session_id) do
    conn
    |> put_req_header("mcp-session-id", session_id)
    |> sse_get(token)
  end

  # Registry registration is the only observable "stream is live" signal, and it
  # happens inside another process — poll it rather than race the first POST.
  defp await_stream_pid(session_id, tries_left) do
    case Registry.lookup(Session.registry(), session_id) do
      [{pid, _}] ->
        pid

      [] when tries_left > 0 ->
        Process.sleep(10)
        await_stream_pid(session_id, tries_left - 1)

      [] ->
        flunk("SSE stream for #{session_id} never registered")
    end
  end

  defp advertised_endpoint(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> uri -> String.trim(uri)
      _ -> nil
    end)
  end

  # Decode every `event: message` frame's `data:` payload, in stream order.
  defp message_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "event: message\n"))
    |> Enum.map(fn frame ->
      "event: message\ndata: " <> payload = String.trim_trailing(frame, "\n")
      Jason.decode!(payload)
    end)
  end
end
