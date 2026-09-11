defmodule ArbiterWeb.MCP.Plug do
  @moduledoc """
  The `Arbiter.MCP` HTTP transport: a JSON-RPC 2.0 endpoint mounted in-process on
  the Phoenix endpoint (Bandit, :4848) and forwarded at `/mcp` (see
  `ArbiterWeb.Router`).

  ## Transport contract

  `/mcp` serves **both** MCP HTTP transports, and which one a request gets is
  decided by one explicit signal: the `sessionId` query parameter on a POST.

  ### Streamable HTTP (MCP 2025-03-26 / 2025-06-18) — the default

    * **`POST /mcp`** with **no `sessionId` query parameter** — the client →
      server request/response channel. The reply is returned **inline** as a
      single `application/json` body. The `initialize` response carries an
      `Mcp-Session-Id` header the client threads back on later requests and on
      the GET stream.
    * **`GET /mcp`** with `Accept: text/event-stream` — the server → client SSE
      stream, held open with periodic keepalives. Server-initiated messages are
      routed to it via `ArbiterWeb.MCP.Session`.

  Clients: Claude Code (`"type": "http"`), Gemini CLI (`httpUrl`), Codex CLI
  (`[mcp_servers.*] url`). This is what every config Arbiter generates uses —
  see `Arbiter.MCP.AgentConfig.Claude`, `.Gemini`, `.Codex` and the CLI's
  `.mcp.json` template.

  ### HTTP+SSE (MCP 2024-11-05, deprecated but still spoken)

    * **`GET /mcp`** with `Accept: text/event-stream` emits an `event: endpoint`
      frame whose `data:` line is the POST-back URL. That URL carries a
      **`sessionId` query parameter** naming the stream just opened (plus any
      `?token=` the stream authenticated with).
    * **`POST` to that advertised URL** — because it carries `sessionId`, the
      reply is **not** returned inline. The POST is acknowledged with **`202
      Accepted` and an empty body**, and the JSON-RPC reply is written to the
      matching SSE stream as an `event: message` frame. A `sessionId` with no
      open stream is `404` rather than a silent inline answer, so a client whose
      stream died fails loudly instead of hanging on a reply that went nowhere.

  Clients: Claude Code (`"type": "sse"`), Antigravity / `agy`, and anything else
  pinned to the 2024-11-05 transport. Because the SSE stream is coordinator-tier
  (below), only a coordinator token can use this transport; worker spawns are
  configured for Streamable HTTP.

  A GET without `Accept: text/event-stream`, or any other verb, is `405`.

  ## Capability is the token

  Every request must carry `Authorization: Bearer <scope-token>`. The token is
  decoded to an `Arbiter.MCP.Scope` (`from_token/1`); an invalid/expired/missing
  token is rejected with HTTP `401`. The SSE stream is a coordinator-tier
  channel: a worker token is also rejected `401` on GET, so workspace isolation
  holds. In-scope-but-not-permitted tool calls are rejected with a JSON-RPC
  **error** object (not a transport error), so the agent gets a usable "not
  allowed". Tool dispatch and capability gating live in `Arbiter.MCP.Catalog`;
  this plug only frames JSON-RPC.

  ## Methods

    * `initialize` — handshake; negotiates protocol version, advertises `tools`,
      assigns the session id.
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
  alias ArbiterWeb.MCP.Session

  @supported_protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @latest_protocol_version "2025-06-18"

  # JSON-RPC standard error codes.
  @code_parse_error -32_700
  @code_invalid_request -32_600
  @code_method_not_found -32_601

  @impl true
  def init(opts), do: opts

  @impl true
  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def call(conn, _opts) do
    cond do
      not MCP.enabled?() ->
        send_json(conn, 404, %{
          "error" => %{"type" => "not_found", "message" => "MCP server disabled"}
        })

      conn.method == "POST" ->
        case authenticate(conn) do
          {:ok, scope} -> handle_rpc(conn, scope)
          {:error, reason} -> unauthorized(conn, reason)
        end

      conn.method == "GET" and accepts_event_stream?(conn) ->
        # The server → client SSE stream, shared by both transports.
        # Coordinator-only.
        case authenticate(conn) do
          {:ok, %Scope{tier: :coordinator} = scope} -> open_sse(conn, scope)
          {:ok, %Scope{}} -> unauthorized(conn, :forbidden)
          {:error, reason} -> unauthorized(conn, reason)
        end

      true ->
        # A GET without `Accept: text/event-stream`, or any other verb.
        send_json(conn, 405, %{
          "error" => %{
            "type" => "method_not_allowed",
            "message" => "POST JSON-RPC, or GET with Accept: text/event-stream"
          }
        })
    end
  end

  # ---- authentication -----------------------------------------------------

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Scope.from_token(String.trim(token))
      _ -> authenticate_from_query(conn)
    end
  end

  defp authenticate_from_query(conn) do
    case conn.query_params do
      %{"token" => token} when is_binary(token) and token != "" ->
        Scope.from_token(token)

      _ ->
        {:error, :missing}
    end
  end

  defp unauthorized(conn, reason) do
    message =
      case reason do
        :expired -> "Scope token expired"
        :missing -> "Missing scope token (Authorization: Bearer <token> or ?token=<token>)"
        :forbidden -> "Coordinator scope required for the SSE stream"
        _ -> "Invalid scope token"
      end

    send_json(conn, 401, %{"error" => %{"type" => "unauthorized", "message" => message}})
  end

  # ---- GET: server → client SSE stream ------------------------------------

  defp accepts_event_stream?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  # Open the chunked SSE stream, register the session for routing, flush an
  # initial keepalive, then hold the connection open until the client
  # disconnects or the configured lifetime elapses.
  defp open_sse(conn, _scope) do
    session_id = register_stream(resolve_session_id(conn))

    conn =
      conn
      |> put_resp_header("mcp-session-id", session_id)
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    uri = endpoint_uri(conn, session_id)

    payload = """
    : arbiter-mcp session=#{session_id}

    event: endpoint
    data: #{uri}

    """

    case chunk(conn, payload) do
      {:ok, conn} -> sse_loop(conn, sse_deadline())
      {:error, _closed} -> conn
    end
  end

  # Claim `session_id` for this stream. A second GET for an id that already has
  # a live stream falls back to a fresh id rather than opening an unroutable
  # stream — the advertised endpoint then names the id that actually routes here.
  defp register_stream(session_id) do
    case Session.register(session_id) do
      :ok -> session_id
      {:error, :already_registered} -> register_stream(Session.new_id())
    end
  end

  # The POST-back URL advertised to HTTP+SSE clients. Same path (Arbiter serves
  # GET and POST on `/mcp`), the stream's own query string preserved so a
  # `?token=` carries over, plus the `sessionId` that routes a POST's reply back
  # to this stream.
  defp endpoint_uri(conn, session_id) do
    query =
      conn.query_string
      |> URI.decode_query()
      |> Map.put("sessionId", session_id)
      |> URI.encode_query()

    conn.request_path <> "?" <> query
  end

  # Each pass waits up to the keepalive interval (bounded by the stream deadline)
  # for a routed message; on idle it flushes a keepalive comment. A `chunk/2`
  # error means the client hung up. Returning the conn closes the stream.
  defp sse_loop(conn, deadline) do
    case sse_wait(deadline) do
      :closed ->
        conn

      {:message, message} ->
        case chunk(conn, sse_event(message)) do
          {:ok, conn} -> sse_loop(conn, deadline)
          {:error, _closed} -> conn
        end

      :keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, deadline)
          {:error, _closed} -> conn
        end
    end
  end

  # Block for the next stream action: a routed message, an explicit close, a
  # keepalive tick, or :closed once the lifetime deadline has passed.
  defp sse_wait(deadline) do
    case keepalive_timeout(deadline) do
      timeout when timeout <= 0 ->
        :closed

      timeout ->
        receive do
          {:mcp_sse, message} -> {:message, message}
          :mcp_sse_close -> :closed
        after
          timeout -> :keepalive
        end
    end
  end

  defp sse_deadline do
    case MCP.sse_max_lifetime_ms() do
      :infinity -> :infinity
      ms -> System.monotonic_time(:millisecond) + ms
    end
  end

  defp keepalive_timeout(:infinity), do: MCP.sse_keepalive_ms()

  defp keepalive_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    min(remaining, MCP.sse_keepalive_ms())
  end

  # Frame a server-initiated JSON-RPC message as one SSE `data:` event.
  defp sse_event(message) do
    payload = if is_binary(message), do: message, else: Jason.encode!(message)
    "event: message\ndata: #{payload}\n\n"
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

    case routed_session_id(conn) do
      nil -> reply_inline(conn, method, response)
      session_id -> reply_on_stream(conn, session_id, response)
    end
  end

  # Streamable HTTP: the answer is the POST's own body.
  defp reply_inline(conn, method, response) do
    conn
    |> maybe_assign_session(method)
    |> send_json(200, response)
  end

  # HTTP+SSE: acknowledge the POST and write the answer to the named stream.
  defp reply_on_stream(conn, session_id, response) do
    case Session.notify(session_id, response) do
      :ok ->
        conn
        |> put_resp_header("mcp-session-id", session_id)
        |> send_resp(202, "")

      {:error, :no_session} ->
        send_json(conn, 404, %{
          "error" => %{
            "type" => "no_session",
            "message" => "No open SSE stream for session #{session_id}"
          }
        })
    end
  end

  # The `sessionId` query parameter is the only signal that selects the
  # HTTP+SSE transport: it is present exactly when the client POSTed to the URL
  # the `endpoint` event advertised.
  defp routed_session_id(conn) do
    case conn.query_params do
      %{"sessionId" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # The `initialize` response mints the session id the client threads back on
  # later POSTs and on the GET SSE stream. Reuse a client-supplied id if present.
  defp maybe_assign_session(conn, "initialize") do
    put_resp_header(conn, "mcp-session-id", resolve_session_id(conn))
  end

  defp maybe_assign_session(conn, _method), do: conn

  defp resolve_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> Session.new_id()
    end
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
