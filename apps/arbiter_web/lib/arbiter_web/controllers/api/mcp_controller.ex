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

  Coordinator tokens are **workspace-agnostic** by default: a single token is
  valid for any workspace on the installation, and coordinator API endpoints /
  MCP tools resolve the target workspace per call (explicit `workspace` param
  → referenced entity → installation default).

  Body parameters:
    - `ttl` (optional) — token lifetime in seconds, default 30 days
    - `workspace_id` (optional) — bind the minted token to one workspace
    - `can_dispatch` (optional, default `true`) — whether the minted token may
      dispatch. Ignored (forced to `false`) when it would exceed the caller.

  ## Caller-inheritance guardrail (bd-5b5hq7)

  An anonymous loopback call (no `Authorization` header — the zero-setup
  `arb` / `arb init` path, `ArbiterWeb.Plugs.ApiAuth`) mints an unrestricted
  token exactly as before: workspace-agnostic, `can_dispatch: true`, no
  `session_id`.

  A call that presents a bearer token (`conn.assigns[:mcp_scope]`, set by
  `ApiAuth` whenever one was given, loopback or not) can only mint a token
  **no more powerful than itself**:

    * the minted token inherits the caller's `session_id`, if any — so ending
      that session revokes the new token too, closing the escalation path
      where a browser session's limited, revocable token is traded for an
      unrestricted one via this same endpoint;
    * the minted token's `workspace_id` is the caller's if the caller is
      workspace-bound (a bound caller cannot mint an unbound or
      differently-bound token); an unbound caller may still narrow via the
      `workspace_id` param;
    * `can_dispatch` is `requested and caller.can_dispatch` — never more
      permissive than the caller.

  A `:worker`-tier caller is refused outright (403): workers have no business
  minting new tokens at all.
  """
  def mint_token(conn, params) do
    ttl = parse_ttl(Map.get(params, "ttl"))

    case conn.assigns[:mcp_scope] do
      nil ->
        token = Scope.mint_coordinator(nil, max_age: ttl)
        respond_token(conn, token, ttl)

      %Scope{tier: :worker} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          "error" => %{"message" => "a worker-tier token cannot mint new tokens"}
        })

      %Scope{} = caller ->
        workspace_id =
          narrow_workspace(caller.workspace_id, nilable_param(params, "workspace_id"))

        can_dispatch = narrow_can_dispatch(caller.can_dispatch, Map.get(params, "can_dispatch"))

        token =
          if caller.session_id do
            Scope.mint_session(caller.session_id,
              workspace_id: workspace_id,
              can_dispatch: can_dispatch,
              max_age: ttl
            )
          else
            Scope.mint_coordinator(workspace_id, can_dispatch: can_dispatch, max_age: ttl)
          end

        respond_token(conn, token, ttl)
    end
  end

  defp respond_token(conn, token, ttl) do
    {:ok, scope} = Scope.from_token(token)

    json(conn, %{
      "token" => token,
      "tier" => "coordinator",
      "workspace_id" => scope.workspace_id,
      "expires_in" => ttl,
      "server_url" => MCP.server_url()
    })
  end

  # A bound caller cannot mint an unbound (or differently-bound) token — the
  # caller's binding is the ceiling. An unbound caller may still narrow.
  defp narrow_workspace(nil, requested), do: requested
  defp narrow_workspace(caller_ws, _requested), do: caller_ws

  defp narrow_can_dispatch(caller_can_dispatch, requested) do
    requested_bool =
      case requested do
        b when is_boolean(b) -> b
        _ -> true
      end

    caller_can_dispatch and requested_bool
  end

  defp nilable_param(params, key) do
    case Map.get(params, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
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
          "task_id" => scope.task_id,
          "repo" => scope.repo,
          "session_id" => scope.session_id,
          "can_dispatch" => scope.can_dispatch,
          "depth" => scope.depth
        })

      {:error, reason} when reason in [:expired, :revoked] ->
        conn
        |> put_status(:ok)
        |> json(%{"valid" => false, "reason" => to_string(reason)})

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
