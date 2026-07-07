defmodule ArbiterWeb.MCP.PlugTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.MCP.Scope

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-plug-ws", prefix: "mcpw"})
    {:ok, task} = Ash.create(Issue, %{title: "plug task", workspace_id: ws.id})

    worker_token = Scope.mint_worker(task, "shipyard")
    coordinator_token = Scope.mint_coordinator(ws.id)

    {:ok,
     conn: conn,
     ws: ws,
     task: task,
     worker_token: worker_token,
     coordinator_token: coordinator_token}
  end

  # POST a JSON-RPC request with a bearer token; return the conn.
  defp rpc(conn, token, request) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/mcp", Jason.encode!(request))
  end

  # POST a JSON-RPC request with a token in the query parameter.
  defp rpc_with_query_token(conn, token, request) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp?token=#{URI.encode_www_form(token)}", Jason.encode!(request))
  end

  defp req(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  describe "initialize" do
    test "negotiates a protocol version and advertises the tools capability", ctx do
      conn =
        rpc(ctx.conn, ctx.worker_token, req("initialize", %{"protocolVersion" => "2025-06-18"}))

      assert %{"result" => result, "id" => 1, "jsonrpc" => "2.0"} = json_response(conn, 200)
      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "arbiter"
      assert is_map(result["capabilities"]["tools"])
    end

    test "falls back to the latest supported version for an unknown one", ctx do
      conn =
        rpc(ctx.conn, ctx.worker_token, req("initialize", %{"protocolVersion" => "1999-01-01"}))

      assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-06-18"
    end
  end

  describe "authentication" do
    test "a request with no Authorization header is 401", ctx do
      conn =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(req("tools/list")))

      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "a garbage token is 401", ctx do
      conn = rpc(ctx.conn, "garbage", req("tools/list"))
      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "a valid token in the query parameter is accepted", ctx do
      conn = rpc_with_query_token(ctx.conn, ctx.worker_token, req("tools/list"))
      assert json_response(conn, 200)["result"]["tools"] != nil
    end

    test "a garbage token in the query parameter is 401", ctx do
      conn = rpc_with_query_token(ctx.conn, "garbage", req("tools/list"))
      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "Authorization header takes precedence over query parameter", ctx do
      conn =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.coordinator_token}")
        |> post("/mcp?token=garbage", Jason.encode!(req("tools/list")))

      assert json_response(conn, 200)["result"]["tools"] != nil
    end

    test "an empty query parameter is treated as missing", ctx do
      conn =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp?token=", Jason.encode!(req("tools/list")))

      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end
  end

  describe "tools/list" do
    test "a worker does not see coordinator-only tools", ctx do
      conn = rpc(ctx.conn, ctx.worker_token, req("tools/list"))
      names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])

      assert "task_show" in names
      refute "task_ready" in names
    end

    test "a coordinator sees coordinator-only tools", ctx do
      conn = rpc(ctx.conn, ctx.coordinator_token, req("tools/list"))
      names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])

      assert "task_ready" in names
    end

    test "tools advertise an inputSchema (camelCase wire field)", ctx do
      conn = rpc(ctx.conn, ctx.worker_token, req("tools/list"))
      [tool | _] = json_response(conn, 200)["result"]["tools"]
      assert tool["inputSchema"]["type"] == "object"
    end
  end

  describe "tools/call" do
    test "a worker reads its own task, returning structuredContent", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.worker_token,
          req("tools/call", %{"name" => "task_show", "arguments" => %{}})
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["id"] == ctx.task.id
      assert [%{"type" => "text"} | _] = result["content"]
    end

    test "an out-of-scope call is rejected with a JSON-RPC error, not a transport error", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.worker_token,
          req("tools/call", %{"name" => "task_ready", "arguments" => %{}})
        )

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32_003
      refute Map.has_key?(body, "result")
    end

    test "an operational failure (not found) is an isError tool result", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("tools/call", %{"name" => "task_show", "arguments" => %{"id" => "bd-nope"}})
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == true
    end

    test "an unknown tool is a JSON-RPC invalid-params error", ctx do
      conn = rpc(ctx.conn, ctx.coordinator_token, req("tools/call", %{"name" => "nope"}))
      assert json_response(conn, 200)["error"]["code"] == -32_602
    end
  end

  describe "Phase 2 coordinator mutations" do
    test "a coordinator creates a task end-to-end via tools/call", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("tools/call", %{
            "name" => "task_create",
            "arguments" => %{"title" => "via mcp", "priority" => 1}
          })
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["title"] == "via mcp"
      assert result["structuredContent"]["workspace_id"] == ctx.ws.id
    end

    test "a worker cannot call a coordinator-only mutating tool", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.worker_token,
          req("tools/call", %{
            "name" => "task_create",
            "arguments" => %{"title" => "nope"}
          })
        )

      assert json_response(conn, 200)["error"]["code"] == -32_003
    end

    test "workspace_config_set accepts a real JSON array value end-to-end (bd-1dtufq)", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("tools/call", %{
            "name" => "workspace_config_set",
            "arguments" => %{"key" => "agent.type", "value" => ["claude", "gemini"]}
          })
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["config"]["agent"]["type"] == ["claude", "gemini"]
    end

    test "workspace_config_set unwraps a client-stringified JSON array (bd-1dtufq)", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("tools/call", %{
            "name" => "workspace_config_set",
            "arguments" => %{"key" => "agent.type", "value" => "[\"claude\", \"gemini\"]"}
          })
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["config"]["agent"]["type"] == ["claude", "gemini"]
    end

    test "worker_dispatch without can_dispatch is a JSON-RPC not-permitted error", ctx do
      no_dispatch = Scope.mint_coordinator(ctx.ws.id, can_dispatch: false)

      conn =
        rpc(
          ctx.conn,
          no_dispatch,
          req("tools/call", %{
            "name" => "worker_dispatch",
            "arguments" => %{"task_id" => ctx.task.id}
          })
        )

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32_003
      assert body["error"]["message"] =~ "can_dispatch"
    end
  end

  describe "protocol edges" do
    test "an unknown method is method-not-found", ctx do
      conn = rpc(ctx.conn, ctx.worker_token, req("frobnicate"))
      assert json_response(conn, 200)["error"]["code"] == -32_601
    end

    test "a notification (no id) is accepted with 202 and no body", ctx do
      conn =
        rpc(ctx.conn, ctx.worker_token, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert response(conn, 202) == ""
    end

    test "ping returns an empty result", ctx do
      conn = rpc(ctx.conn, ctx.worker_token, req("ping"))
      assert json_response(conn, 200)["result"] == %{}
    end

    test "a GET without Accept: text/event-stream is 405", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{ctx.coordinator_token}")
        |> get("/mcp")

      assert json_response(conn, 405)["error"]["type"] == "method_not_allowed"
    end
  end

  describe "session id" do
    test "initialize assigns an Mcp-Session-Id header", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("initialize", %{"protocolVersion" => "2025-03-26"})
        )

      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert is_binary(session_id) and session_id != ""
    end

    test "a non-initialize request does not assign a session id", ctx do
      conn = rpc(ctx.conn, ctx.coordinator_token, req("tools/list"))
      assert get_resp_header(conn, "mcp-session-id") == []
    end
  end

  describe "GET SSE stream (Streamable HTTP)" do
    # Open the SSE stream with a bearer token and an event-stream Accept header.
    defp sse(conn, token) do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "text/event-stream")
      |> get("/mcp")
    end

    # Open the SSE stream with a token in the query parameter.
    defp sse_with_query_token(conn, token) do
      conn
      |> put_req_header("accept", "text/event-stream")
      |> get("/mcp?token=#{URI.encode_www_form(token)}")
    end

    test "a coordinator opens a 200 text/event-stream and gets an initial event", ctx do
      conn = sse(ctx.conn, ctx.coordinator_token)

      assert conn.status == 200

      assert {"content-type", "text/event-stream" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert conn.resp_body =~ "arbiter-mcp session=#{session_id}"
    end

    test "a worker token is rejected on GET (401) — workspace isolation holds", ctx do
      conn = sse(ctx.conn, ctx.worker_token)
      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "an unauthenticated GET is 401", ctx do
      conn =
        ctx.conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/mcp")

      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end

    test "the stream honors a client-supplied Mcp-Session-Id", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{ctx.coordinator_token}")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", "client-chosen-id")
        |> get("/mcp")

      assert get_resp_header(conn, "mcp-session-id") == ["client-chosen-id"]
      assert conn.resp_body =~ "client-chosen-id"
    end

    test "a coordinator token in the query parameter opens an SSE stream", ctx do
      conn = sse_with_query_token(ctx.conn, ctx.coordinator_token)

      assert conn.status == 200

      assert {"content-type", "text/event-stream" <> _} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert conn.resp_body =~ "arbiter-mcp session=#{session_id}"
    end

    test "a garbage token in the query parameter is 401 on SSE", ctx do
      conn = sse_with_query_token(ctx.conn, "garbage")
      assert json_response(conn, 401)["error"]["type"] == "unauthorized"
    end
  end

  describe "tools/list over an SSE-established session" do
    test "returns the same coordinator catalog as a plain POST", ctx do
      init =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("initialize", %{"protocolVersion" => "2025-03-26"})
        )

      assert [session_id] = get_resp_header(init, "mcp-session-id")

      conn =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.coordinator_token}")
        |> put_req_header("mcp-session-id", session_id)
        |> post("/mcp", Jason.encode!(req("tools/list", %{}, 2)))

      names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])
      assert "task_ready" in names
      assert "task_show" in names
    end
  end
end
