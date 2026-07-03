defmodule ArbiterWeb.Plugs.ApiAuth do
  @moduledoc """
  Loopback-exempt token authentication for the `/api` pipeline.

  Requests from `127.0.0.1` or `::1` are allowed through without a token so
  local `arb` CLI usage and same-box tooling are unaffected. All other origins
  must present a valid `Authorization: Bearer <token>` using the same signed
  MCP scope token mechanism used by the `/mcp` endpoint.

  Rejects unauthenticated non-loopback requests with HTTP 401 and a JSON error
  body matching the API error shape: `%{"error" => %{"message" => "..."}}`.

  Do NOT trust `X-Forwarded-For` — arbiter binds directly (no reverse proxy)
  so `conn.remote_ip` is always the real peer.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.MCP.Scope

  @loopback_ipv4 {127, 0, 0, 1}
  @loopback_ipv6 {0, 0, 0, 0, 0, 0, 0, 1}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{remote_ip: ip} = conn, _opts) when ip in [@loopback_ipv4, @loopback_ipv6] do
    conn
  end

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Scope.from_token(String.trim(token)) do
          {:ok, _scope} -> conn
          {:error, :expired} -> halt_unauthorized(conn, "Bearer token expired")
          {:error, _} -> halt_unauthorized(conn, "Invalid Bearer token")
        end

      _ ->
        halt_unauthorized(conn, "Authorization: Bearer <token> required")
    end
  end

  defp halt_unauthorized(conn, message) do
    body = Jason.encode!(%{"error" => %{"message" => message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
