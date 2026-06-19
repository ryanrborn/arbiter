defmodule ArbiterWeb.Api.McpController do
  @moduledoc """
  API endpoints for minting and verifying MCP scope tokens.

  Routes:

    * `POST /api/mcp/tokens`        — :mint_token   Mint a coordinator scope token
    * `POST /api/mcp/tokens/verify` — :verify_token Decode + verify a scope token

  These endpoints are used by `arb mcp token mint` and `arb mcp token verify`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.MCP
  alias Arbiter.MCP.Scope

  @default_ttl 30 * 24 * 60 * 60

  action_fallback ArbiterWeb.Api.FallbackController

  @doc """
  Mint a coordinator-tier scope token.

  Coordinator tokens are **workspace-agnostic**: a single token is valid for any
  workspace on the installation, and coordinator API endpoints / MCP tools resolve
  the target workspace per call (explicit `workspace` param → referenced entity →
  installation default). No workspace is bound at mint time.

  Body parameters:
    - `ttl` (optional) — token lifetime in seconds, default 30 days

  A `workspace_id` may still be supplied for backward compatibility; it is
  ignored (the minted token is not bound to it).
  """
  def mint_token(conn, params) do
    ttl = parse_ttl(Map.get(params, "ttl"))
    token = Scope.mint_coordinator(nil, max_age: ttl)

    json(conn, %{
      "token" => token,
      "tier" => "coordinator",
      "workspace_id" => nil,
      "expires_in" => ttl,
      "server_url" => MCP.server_url()
    })
  end

  @doc """
  Verify a scope token and return its decoded claims.

  Body parameters:
    - `token` (required) — the signed scope token to verify

  Returns `{"valid": true, ...claims}` or `{"valid": false, "reason": "..."}`.
  """
  def verify_token(conn, %{"token" => token}) when is_binary(token) and token != "" do
    case Scope.from_token(token) do
      {:ok, scope} ->
        json(conn, %{
          "valid" => true,
          "tier" => to_string(scope.tier),
          "workspace_id" => scope.workspace_id,
          "bead_id" => scope.bead_id,
          "repo" => scope.repo,
          "can_dispatch" => scope.can_dispatch,
          "depth" => scope.depth
        })

      {:error, :expired} ->
        conn
        |> put_status(:ok)
        |> json(%{"valid" => false, "reason" => "expired"})

      {:error, _} ->
        conn
        |> put_status(:ok)
        |> json(%{"valid" => false, "reason" => "invalid"})
    end
  end

  def verify_token(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"message" => "token is required"}})
  end

  defp parse_ttl(nil), do: @default_ttl
  defp parse_ttl(n) when is_integer(n) and n > 0, do: n

  defp parse_ttl(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> @default_ttl
    end
  end

  defp parse_ttl(_), do: @default_ttl
end
