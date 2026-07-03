defmodule ArbiterWeb.Plugs.ApiAuth do
  @moduledoc """
  Loopback-exempt token authentication for the `/api` pipeline.

  Requests from loopback addresses (`127.0.0.0/8`, `::1`, or IPv4-mapped IPv6
  loopback `::ffff:127.x.x.x`) are allowed through without a token so local
  `arb` CLI usage and same-box tooling are unaffected. All other origins must
  present a valid `Authorization: Bearer <token>` using the same signed MCP
  scope token mechanism used by the `/mcp` endpoint.

  Rejects unauthenticated non-loopback requests with HTTP 401 and a JSON error
  body matching the API error shape: `%{"error" => %{"message" => "..."}}`.

  Do NOT trust `X-Forwarded-For` — arbiter binds directly (no reverse proxy)
  so `conn.remote_ip` is always the real peer.
  """

  @behaviour Plug

  import Plug.Conn
  import Bitwise

  alias Arbiter.MCP.Scope

  @impl true
  def init(opts), do: opts

  @impl true
  # IPv4 loopback 127.0.0.0/8
  def call(%Plug.Conn{remote_ip: {127, _, _, _}} = conn, _opts) do
    conn
  end

  # IPv6 loopback ::1
  def call(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}} = conn, _opts) do
    conn
  end

  # IPv4-mapped IPv6 loopback ::ffff:127.x.x.x
  def call(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0xffff, hi, _lo}} = conn, _opts) do
    case hi >>> 8 do
      127 -> conn
      _ -> require_bearer(conn)
    end
  end

  # Non-loopback addresses require a token
  def call(conn, _opts) do
    require_bearer(conn)
  end

  defp require_bearer(conn) do
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
