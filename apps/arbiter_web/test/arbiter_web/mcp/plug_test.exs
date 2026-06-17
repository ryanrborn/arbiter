defmodule ArbiterWeb.MCP.PlugTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP.Scope

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-plug-ws", prefix: "mcpw"})
    {:ok, bead} = Ash.create(Issue, %{title: "plug bead", workspace_id: ws.id})

    polecat_token = Scope.mint_polecat(bead, "shipyard")
    coordinator_token = Scope.mint_coordinator(ws.id)

    {:ok,
     conn: conn,
     ws: ws,
     bead: bead,
     polecat_token: polecat_token,
     coordinator_token: coordinator_token}
  end

  # POST a JSON-RPC request with a bearer token; return the conn.
  defp rpc(conn, token, request) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/mcp", Jason.encode!(request))
  end

  defp req(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  describe "initialize" do
    test "negotiates a protocol version and advertises the tools capability", ctx do
      conn =
        rpc(ctx.conn, ctx.polecat_token, req("initialize", %{"protocolVersion" => "2025-06-18"}))

      assert %{"result" => result, "id" => 1, "jsonrpc" => "2.0"} = json_response(conn, 200)
      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "arbiter"
      assert is_map(result["capabilities"]["tools"])
    end

    test "falls back to the latest supported version for an unknown one", ctx do
      conn =
        rpc(ctx.conn, ctx.polecat_token, req("initialize", %{"protocolVersion" => "1999-01-01"}))

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
  end

  describe "tools/list" do
    test "a polecat does not see coordinator-only tools", ctx do
      conn = rpc(ctx.conn, ctx.polecat_token, req("tools/list"))
      names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])

      assert "bead_show" in names
      refute "bead_ready" in names
    end

    test "a coordinator sees coordinator-only tools", ctx do
      conn = rpc(ctx.conn, ctx.coordinator_token, req("tools/list"))
      names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])

      assert "bead_ready" in names
    end

    test "tools advertise an inputSchema (camelCase wire field)", ctx do
      conn = rpc(ctx.conn, ctx.polecat_token, req("tools/list"))
      [tool | _] = json_response(conn, 200)["result"]["tools"]
      assert tool["inputSchema"]["type"] == "object"
    end
  end

  describe "tools/call" do
    test "a polecat reads its own bead, returning structuredContent", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.polecat_token,
          req("tools/call", %{"name" => "bead_show", "arguments" => %{}})
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["id"] == ctx.bead.id
      assert [%{"type" => "text"} | _] = result["content"]
    end

    test "an out-of-scope call is rejected with a JSON-RPC error, not a transport error", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.polecat_token,
          req("tools/call", %{"name" => "bead_ready", "arguments" => %{}})
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
          req("tools/call", %{"name" => "bead_show", "arguments" => %{"id" => "bd-nope"}})
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
    test "a coordinator creates a bead end-to-end via tools/call", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.coordinator_token,
          req("tools/call", %{
            "name" => "bead_create",
            "arguments" => %{"title" => "via mcp", "priority" => 1}
          })
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["structuredContent"]["title"] == "via mcp"
      assert result["structuredContent"]["workspace_id"] == ctx.ws.id
    end

    test "a polecat cannot call a coordinator-only mutating tool", ctx do
      conn =
        rpc(
          ctx.conn,
          ctx.polecat_token,
          req("tools/call", %{
            "name" => "bead_create",
            "arguments" => %{"title" => "nope"}
          })
        )

      assert json_response(conn, 200)["error"]["code"] == -32_003
    end

    test "polecat_sling without can_sling is a JSON-RPC not-permitted error", ctx do
      no_sling = Scope.mint_coordinator(ctx.ws.id, can_sling: false)

      conn =
        rpc(
          ctx.conn,
          no_sling,
          req("tools/call", %{
            "name" => "polecat_sling",
            "arguments" => %{"bead_id" => ctx.bead.id}
          })
        )

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32_003
      assert body["error"]["message"] =~ "can_sling"
    end
  end

  describe "protocol edges" do
    test "an unknown method is method-not-found", ctx do
      conn = rpc(ctx.conn, ctx.polecat_token, req("frobnicate"))
      assert json_response(conn, 200)["error"]["code"] == -32_601
    end

    test "a notification (no id) is accepted with 202 and no body", ctx do
      conn =
        rpc(ctx.conn, ctx.polecat_token, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert response(conn, 202) == ""
    end

    test "ping returns an empty result", ctx do
      conn = rpc(ctx.conn, ctx.polecat_token, req("ping"))
      assert json_response(conn, 200)["result"] == %{}
    end

    test "GET is not supported (405)", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{ctx.polecat_token}")
        |> get("/mcp")

      assert json_response(conn, 405)["error"]["type"] == "method_not_allowed"
    end
  end
end
