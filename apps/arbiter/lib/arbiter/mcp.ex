defmodule Arbiter.MCP do
  @moduledoc """
  Arbiter's single in-process Model Context Protocol server — the agent-native
  route back into the domain (read your bead, check your mailbox, write your
  completion notes) as schema-backed tool calls instead of `arb …` argv guessing.

  This module is the **domain-side seam**: config, the signed scope-token mint /
  verify path, and the server URL used when injecting per-spawn agent config. The
  HTTP transport (JSON-RPC over Streamable HTTP) lives in the web app
  (`ArbiterWeb.MCP.Plug`); the capability model lives in `Arbiter.MCP.Scope`; the
  tool catalog in `Arbiter.MCP.Catalog`. See `docs/mcp-server-design.md`.

  ## Capability is a token, not a code path

  Every MCP connection presents a bearer token minted **per spawn** with the
  caller's tier + bound identity baked in (`Arbiter.MCP.Scope`). The token is a
  signed, expiring blob (the same `Plug.Crypto` primitive `Phoenix.Token` wraps)
  — tamper-evident and self-describing, so the transport can decode it to claims
  and reject out-of-scope calls without trusting the agent.

  ## Configuration

      config :arbiter, Arbiter.MCP,
        enabled: true,           # master switch (default true)
        inject_config: true,     # write a per-spawn .mcp.json into the worktree
        url: "http://127.0.0.1:4848/mcp",  # overrides the derived endpoint URL
        secret: "…",             # overrides the endpoint secret_key_base for signing
        max_age: 86_400,         # token TTL in seconds (default 24h)
        max_depth: 3,            # sling-recursion depth cap (Phase 2 guardrail)
        server_name: "arbiter"   # the mcpServers key in .mcp.json

  All keys are optional; the defaults below stand in for a vanilla install.
  """

  @salt "arbiter.mcp.scope.v1"
  @default_max_age 86_400
  @default_max_depth 3
  @default_server_name "arbiter"
  @default_port 4848

  @doc "Whether the MCP server is enabled at all (default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, true) == true

  @doc """
  Whether the spawn path should write a per-spawn `.mcp.json` into the worktree
  (default `true`, and always `false` when the server is disabled).
  """
  @spec inject_config?() :: boolean()
  def inject_config?, do: enabled?() and config(:inject_config, true) == true

  @doc "The signing salt for scope tokens."
  @spec salt() :: String.t()
  def salt, do: @salt

  @doc "Scope-token TTL in seconds (default 24h)."
  @spec max_age() :: pos_integer()
  def max_age, do: config(:max_age, @default_max_age)

  @doc "The sling-recursion depth cap a coordinator token may reach (Phase 2)."
  @spec max_depth() :: non_neg_integer()
  def max_depth, do: config(:max_depth, @default_max_depth)

  @doc "The `mcpServers` key written into `.mcp.json` (default `\"arbiter\"`)."
  @spec server_name() :: String.t()
  def server_name, do: config(:server_name, @default_server_name)

  @doc "The server version reported in the MCP `initialize` handshake (`serverInfo`)."
  @spec server_version() :: String.t()
  def server_version do
    case Application.spec(:arbiter, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  @doc """
  The MCP endpoint URL written into per-spawn agent config. An explicit
  `:url` config wins; otherwise it's derived from the Phoenix endpoint's
  configured HTTP port on loopback.
  """
  @spec server_url() :: String.t()
  def server_url, do: config(:url) || default_server_url()

  @doc """
  Sign `claims` (a map) into an opaque, expiring scope token. Used by
  `Arbiter.MCP.Scope` mint helpers; callers should prefer those.
  """
  @spec mint(map(), keyword()) :: String.t()
  def mint(claims, opts \\ []) when is_map(claims) do
    Plug.Crypto.sign(secret(), @salt, claims, Keyword.put_new(opts, :max_age, max_age()))
  end

  @doc """
  Verify and decode a scope token back into its claims map. Returns
  `{:error, :expired | :invalid}` for an expired / tampered / unparseable token.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, :expired | :invalid}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) do
    # Do not add a default max_age — let Plug.Crypto use the value stored in the
    # token at mint time. This allows coordinator tokens with long TTLs (e.g. 30
    # days) to remain valid beyond the server's default max_age config. Callers
    # may still pass an explicit max_age to tighten the window (e.g. tests use
    # max_age: -1 to force expiry).
    case Plug.Crypto.verify(secret(), @salt, token, opts) do
      {:ok, %{} = claims} -> {:ok, claims}
      {:ok, _other} -> {:error, :invalid}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify(_token, _opts), do: {:error, :invalid}

  # ---- internals ----------------------------------------------------------

  defp secret do
    config(:secret) || endpoint_secret() ||
      raise """
      Arbiter.MCP: no signing secret available. Set one of:
        config :arbiter, Arbiter.MCP, secret: "<64+ random bytes>"
      or the Phoenix endpoint's :secret_key_base.
      """
  end

  defp endpoint_secret do
    :arbiter_web
    |> Application.get_env(ArbiterWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  defp default_server_url, do: "http://127.0.0.1:#{endpoint_port()}/mcp"

  defp endpoint_port do
    :arbiter_web
    |> Application.get_env(ArbiterWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, @default_port)
  end

  defp config(key, default \\ nil) do
    :arbiter
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
