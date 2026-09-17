defmodule ArbiterWeb.Plugs.ApiAuth do
  @moduledoc """
  Loopback-exempt token authentication for the `/api` pipeline.

  Requests from loopback addresses are allowed through without a token so local
  `arb` CLI usage and same-box tooling are unaffected — `ArbiterWeb.Loopback`
  owns which addresses count, shared with `ArbiterWeb.SessionSocket`. All other
  origins must present a valid `Authorization: Bearer <token>` using the same
  signed MCP scope token mechanism used by the `/mcp` endpoint.

  Rejects unauthenticated non-loopback requests with HTTP 401 and a JSON error
  body matching the API error shape: `%{"error" => %{"message" => "..."}}`.

  A caller's decoded `%Scope{}` — when a valid Bearer token was presented, on
  loopback or not — is assigned to `conn.assigns[:mcp_scope]`. `nil` means
  genuinely anonymous: no `Authorization` header at all, the one case
  loopback still lets through unauthenticated. A header that *is* present but
  expired, revoked, or malformed is rejected with 401 on loopback exactly
  like off-loopback — it is never silently downgraded to anonymous. That
  matters because a session's own `arb` CLI now authenticates over loopback
  with its own token (bd-5b5hq7): if that token were revoked (its session
  ended) and the plug just shrugged and treated the request as anonymous, a
  still-running session process would trade a revoked token for a brand-new
  unrestricted one through the exact endpoint meant to stop that
  (`ArbiterWeb.Api.McpController.mint_token/2`, which reads `:mcp_scope` to
  cap what it mints at what the caller already had).

  Do NOT trust `X-Forwarded-For` — arbiter binds directly (no reverse proxy)
  so `conn.remote_ip` is always the real peer.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.MCP.Scope
  alias ArbiterWeb.Loopback

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{remote_ip: remote_ip} = conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Scope.from_token(String.trim(token)) do
          {:ok, scope} -> assign(conn, :mcp_scope, scope)
          {:error, :expired} -> halt_unauthorized(conn, "Bearer token expired")
          {:error, :revoked} -> halt_unauthorized(conn, "Bearer token revoked (session ended)")
          {:error, _} -> halt_unauthorized(conn, "Invalid Bearer token")
        end

      _ ->
        if Loopback.loopback?(remote_ip) do
          assign(conn, :mcp_scope, nil)
        else
          halt_unauthorized(conn, "Authorization: Bearer <token> required")
        end
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
