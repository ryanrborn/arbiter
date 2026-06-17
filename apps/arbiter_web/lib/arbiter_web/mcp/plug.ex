defmodule ArbiterWeb.MCP.Plug do
  @moduledoc """
  The `Arbiter.MCP` HTTP transport: a JSON-RPC 2.0 endpoint over **Streamable
  HTTP**, mounted in-process on the Phoenix endpoint (Bandit, :4848) and forwarded
  at `/mcp` (see `ArbiterWeb.Router`).

  A single endpoint serves POST (the client → server request/response channel).
  Fast calls — every Phase 1 tool — return a single `application/json` body; the
  optional SSE upgrade for long-running calls is a later concern. The deprecated
  two-endpoint HTTP+SSE transport is intentionally not implemented; a GET (the
  server → client stream) is answered `405`.

  ## Capability is the token

  Every request must carry `Authorization: Bearer <scope-token>`. The token is
  decoded to an `Arbiter.MCP.Scope` (`from_token/1`); an invalid/expired/missing
  token is rejected with HTTP `401`. In-scope-but-not-permitted tool calls are
  rejected with a JSON-RPC **error** object (not a transport error), so the agent
  gets a usable "not allowed". Tool dispatch and capability gating live in
  `Arbiter.MCP.Catalog`; this plug only frames JSON-RPC.

  ## Methods

    * `initialize` — handshake; negotiates protocol version, advertises `tools`.
    * `ping` — liveness; returns `{}`.
    * `tools/list` — the tools visible to the connection's scope.
    * `tools/call` — authorize + run one tool.
    * `notifications/*` (and any id-less request) — accepted with `202`, no body.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.MCP
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @supported_protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @latest_protocol_version "2025-06-18"

  # JSON-RPC standard error codes.
  @code_parse_error -32_700
  @code_invalid_request -32_600
  @code_method_not_found -32_601

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not MCP.enabled?() ->
        send_json(conn, 404, %{
          "error" => %{"type" => "not_found", "message" => "MCP server disabled"}
        })

      conn.method != "POST" ->
        # GET (server→client SSE) and other verbs are not supported in Phase 1.
        send_json(conn, 405, %{
          "error" => %{"type" => "method_not_allowed", "message" => "Use POST with JSON-RPC"}
        })

      true ->
        case authenticate(conn) do
          {:ok, scope} -> handle_rpc(conn, scope)
          {:error, reason} -> unauthorized(conn, reason)
        end
    end
  end

  # ---- authentication -----------------------------------------------------

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Scope.from_token(String.trim(token))
      _ -> {:error, :missing}
    end
  end

  defp unauthorized(conn, reason) do
    message =
      case reason do
        :expired -> "Scope token expired"
        :missing -> "Missing Authorization: Bearer <scope-token>"
        _ -> "Invalid scope token"
      end

    send_json(conn, 401, %{"error" => %{"type" => "unauthorized", "message" => message}})
  end

  # ---- JSON-RPC dispatch --------------------------------------------------

  defp handle_rpc(conn, scope) do
    case conn.body_params do
      %{"method" => method} = req when is_binary(method) ->
        dispatch(conn, scope, req)

      # A JSON array body (batch) is wrapped by Plug under "_json". Batching was
      # removed from MCP; reject it rather than partially handle it.
      %{"_json" => _} ->
        send_json(
          conn,
          200,
          error_response(nil, @code_invalid_request, "Batch requests are not supported")
        )

      _ ->
        send_json(conn, 200, error_response(nil, @code_parse_error, "Malformed JSON-RPC request"))
    end
  end

  # An id-less request is a JSON-RPC notification: accept it, return no body.
  defp dispatch(conn, _scope, req) when not is_map_key(req, "id") do
    send_resp(conn, 202, "")
  end

  defp dispatch(conn, scope, %{"id" => id, "method" => method} = req) do
    params = Map.get(req, "params", %{})
    response = handle_method(method, params, scope, id)
    send_json(conn, 200, response)
  end

  defp handle_method("initialize", params, _scope, id) do
    result(id, %{
      "protocolVersion" => negotiate_version(params),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => MCP.server_name(), "version" => MCP.server_version()}
    })
  end

  defp handle_method("ping", _params, _scope, id), do: result(id, %{})

  defp handle_method("tools/list", _params, scope, id) do
    tools =
      scope
      |> Catalog.visible()
      |> Enum.map(fn tool ->
        %{
          "name" => tool.name,
          "description" => tool.description,
          "inputSchema" => tool.input_schema
        }
      end)

    result(id, %{"tools" => tools})
  end

  defp handle_method("tools/call", params, scope, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    if is_binary(name) do
      render_call(id, Catalog.call(scope, name, arguments))
    else
      error_response(id, @code_invalid_request, "tools/call requires a tool `name`")
    end
  end

  defp handle_method(method, _params, _scope, id) do
    error_response(id, @code_method_not_found, "Method not found: #{method}")
  end

  # ---- tools/call result rendering ---------------------------------------

  # Structured success: both a JSON text block (back-compat) and structuredContent.
  defp render_call(id, {:ok, data}) do
    result(id, %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(data)}],
      "structuredContent" => data,
      "isError" => false
    })
  end

  # Operational failure (not-found / bad args): an isError tool result, so the
  # agent gets a usable message and can adjust, not a dropped call.
  defp render_call(id, {:tool_error, message}) do
    result(id, %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    })
  end

  # Scope/tier violation or unknown tool: a JSON-RPC error object.
  defp render_call(id, {:rpc_error, code, message}) do
    error_response(id, code, message)
  end

  # ---- helpers ------------------------------------------------------------

  defp negotiate_version(params) do
    case Map.get(params, "protocolVersion") do
      v when is_binary(v) ->
        if v in @supported_protocol_versions, do: v, else: @latest_protocol_version

      _ ->
        @latest_protocol_version
    end
  end

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
