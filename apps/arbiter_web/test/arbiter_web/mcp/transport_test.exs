defmodule ArbiterWeb.MCP.TransportTest do
  @moduledoc """
  End-to-end coverage for the one transport `ArbiterWeb.MCP.Plug` serves:
  Streamable HTTP. Every JSON-RPC reply must arrive inline on its own POST, the
  `GET` SSE stream must carry only server-initiated messages and must advertise
  no `event: endpoint` handshake (which would promise the HTTP+SSE flow we do
  not serve), and the OAuth discovery paths must stay unrouted.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.MCP.Session

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-transport-ws", prefix: "mcptr"})

    {:ok, conn: conn, ws: ws, token: Scope.mint_coordinator(ws.id)}
  end

  describe "GET stream: the server → client channel only" do
    test "advertises no endpoint event, so no client waits for a reply there", ctx do
      conn = sse_get(ctx.conn, ctx.token)

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      refute conn.resp_body =~ "event: endpoint"
      # Not even an anonymous `data:` frame: the only thing written before a
      # server-initiated message is the session comment.
      refute Enum.any?(String.split(conn.resp_body, "\n"), &String.starts_with?(&1, "data:"))
      assert conn.resp_body =~ ": arbiter-mcp session="
    end

    test "carries a server-initiated message for the id the client presented", ctx do
      extend_sse_lifetime(15_000)

      session_id = "stream-" <> Session.new_id()
      {task, stream_pid} = open_stream(ctx.token, session_id)

      assert :ok = Session.notify(session_id, %{"jsonrpc" => "2.0", "method" => "notify/test"})

      stream = close_stream(task, stream_pid)
      assert [%{"method" => "notify/test"}] = message_events(stream.resp_body)
    end
  end

  describe "Streamable HTTP handshake, end to end" do
    test "initialize then tools/list answer inline, and the stream stays silent", ctx do
      extend_sse_lifetime(15_000)

      init = rpc_post(ctx.token, rpc("initialize", %{"protocolVersion" => "2025-06-18"}, 1))

      body = json_response(init, 200)
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["serverInfo"]["name"] == "arbiter"
      assert [session_id] = get_resp_header(init, "mcp-session-id")

      # The client now opens its server → client stream with the negotiated id,
      # exactly as Streamable HTTP prescribes.
      {task, stream_pid} = open_stream(ctx.token, session_id)

      list = rpc_post(ctx.token, rpc("tools/list", %{}, 2), session_id)
      list_body = json_response(list, 200)
      assert list_body["id"] == 2
      assert "task_ready" in Enum.map(list_body["result"]["tools"], & &1["name"])

      stream = close_stream(task, stream_pid)
      assert message_events(stream.resp_body) == []
    end

    test "a POST carrying a sessionId query parameter still answers inline", ctx do
      extend_sse_lifetime(15_000)

      session_id = "legacy-" <> Session.new_id()
      {task, stream_pid} = open_stream(ctx.token, session_id)

      # `?sessionId=` was the HTTP+SSE disambiguator: it used to be 202-acked
      # with the reply written to the stream. There is no such routing any more —
      # the reply is this POST's body and the stream gets nothing.
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.token}")
        |> post(
          "/mcp?sessionId=#{URI.encode_www_form(session_id)}",
          Jason.encode!(rpc("ping", %{}, 3))
        )

      assert json_response(conn, 200)["id"] == 3

      stream = close_stream(task, stream_pid)
      assert message_events(stream.resp_body) == []
    end
  end

  describe "session id takeover" do
    test "a reconnect with the same id takes it over instead of minting a new one", ctx do
      extend_sse_lifetime(15_000)

      session_id = "reconnect-" <> Session.new_id()
      {first_task, first_pid} = open_stream(ctx.token, session_id)

      # The client reconnects its stream under the id it keeps POSTing with,
      # before the server has reaped the previous one.
      second_task = Task.async(fn -> sse_get(build_conn(), ctx.token, session_id) end)
      second_pid = await_owner_change(session_id, first_pid, 200)

      # The displaced stream is closed out, and the id still routes — to the new
      # stream, under the very id the client presented.
      first = Task.await(first_task, 10_000)
      assert first.status == 200
      assert second_pid != first_pid
      assert [^session_id] = get_resp_header(first, "mcp-session-id")

      assert :ok = Session.notify(session_id, %{"jsonrpc" => "2.0", "method" => "after/takeover"})

      second = close_stream(second_task, second_pid)
      assert [^session_id] = get_resp_header(second, "mcp-session-id")
      assert [%{"method" => "after/takeover"}] = message_events(second.resp_body)
      assert message_events(first.resp_body) == []
    end

    test "a GET is refused 409 while a live stream will not release the id", ctx do
      test_pid = self()
      session_id = "stubborn-" <> Session.new_id()

      # A holder that ignores the close request stands in for a stream that is
      # genuinely still live: the reconnect is refused rather than served under a
      # session id the client never POSTs with.
      holder =
        spawn_link(fn ->
          assert :ok = Session.register(session_id)
          send(test_pid, :registered)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive :registered

      conn = sse_get(build_conn(), ctx.token, session_id)
      assert json_response(conn, 409)["error"]["type"] == "session_in_use"

      send(holder, :release)
    end

    test "the stream releases its session id when it ends", ctx do
      extend_sse_lifetime(15_000)

      session_id = "released-" <> Session.new_id()
      {task, stream_pid} = open_stream(ctx.token, session_id)
      _ = close_stream(task, stream_pid)

      assert Registry.lookup(Session.registry(), session_id) == []
      assert {:error, :no_session} = Session.notify(session_id, %{})
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

  defp rpc(method, params, id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp rpc_post(token, request, session_id \\ nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> then(fn conn ->
      if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn
    end)
    |> post("/mcp", Jason.encode!(request))
  end

  defp sse_get(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "text/event-stream")
    |> get("/mcp")
  end

  defp sse_get(conn, token, session_id) do
    conn
    |> put_req_header("mcp-session-id", session_id)
    |> sse_get(token)
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

  defp close_stream(task, stream_pid) do
    send(stream_pid, :mcp_sse_close)
    Task.await(task, 10_000)
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

  # Takeover completes in the reconnecting request's process; poll until the id
  # is owned by someone other than the stream being displaced.
  defp await_owner_change(session_id, old_pid, tries_left) do
    case Registry.lookup(Session.registry(), session_id) do
      [{pid, _}] when pid != old_pid ->
        pid

      _ when tries_left > 0 ->
        Process.sleep(10)
        await_owner_change(session_id, old_pid, tries_left - 1)

      _ ->
        flunk("session #{session_id} was never taken over from #{inspect(old_pid)}")
    end
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
