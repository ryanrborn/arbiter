defmodule Arbiter.MCP.AgentConfig.Codex do
  @moduledoc """
  OpenAI Codex CLI's `Arbiter.MCP.AgentConfig` adapter (Phase 3).

  Writes a per-spawn `.codex/config.toml` into the acolyte's worktree,
  declaring the Arbiter MCP server as a remote HTTP server with the spawn's
  scope token in a bearer header:

      [mcp_servers.arbiter]
      url = "http://127.0.0.1:4848/mcp"

      [mcp_servers.arbiter.headers]
      Authorization = "Bearer <scope-token>"

  ## Post-spawn connect check

  Codex MCP support is newer than Claude's or Gemini's and has reports of
  **silent connect failures** — Codex starts without error but never actually
  connects to the MCP server. Callers should invoke `verify_connection/1`
  *after* the Codex session is started to confirm the MCP endpoint responds
  to the spawn's token before treating the session as operational.

  `verify_connection/1` sends a minimal MCP `initialize` call to the endpoint
  and returns `:ok` on a successful `200` response, or `{:error, reason}` if
  the endpoint is unreachable, returns an unexpected status, or replies with
  `401 Unauthorized` (indicating a bad / expired token).
  """

  @behaviour Arbiter.MCP.AgentConfig

  @dirname ".codex"
  @filename "config.toml"
  @connect_timeout_ms 5_000

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    dir = Path.join(worktree, @dirname)

    with :ok <- File.mkdir_p(dir),
         toml = config_toml(opts),
         :ok <- File.write(Path.join(dir, @filename), toml) do
      :ok
    end
  end

  @doc """
  The `.codex/config.toml` content as a string. Exposed for tests /
  inspection.

  Requires `:mcp_url` and `:scope_token`. Optional:
  - `:server_name` — defaults to `"arbiter"`.
  """
  @spec config_toml(keyword()) :: String.t()
  def config_toml(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")

    """
    [mcp_servers.#{name}]
    url = #{inspect(url)}

    [mcp_servers.#{name}.headers]
    Authorization = #{inspect("Bearer " <> token)}
    """
  end

  @doc """
  Verify that the MCP server is reachable and the spawn's scope token is
  accepted. Should be called *after* the Codex session is started.

  Sends a minimal MCP `initialize` JSON-RPC call to `:mcp_url` with the
  bearer token from `:scope_token`. Returns `:ok` on a `200` response,
  `{:error, :unauthorized}` on `401`, or `{:error, reason}` for other
  failures.

  This check exists because Codex MCP support has reports of silent connect
  failures — it starts without error but never connects. A `200` here
  confirms the channel is open.
  """
  @spec verify_connection(keyword()) :: :ok | {:error, term()}
  def verify_connection(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)

    req =
      Req.new(
        url: url,
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json"}
        ],
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "arbiter-codex-probe", "version" => "0.0.1"}
          }
        },
        receive_timeout: @connect_timeout_ms
      )

    case Req.post(req) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: 401}} -> {:error, :unauthorized}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  @doc "The config directory name written into the worktree (`.codex`)."
  @spec dirname() :: String.t()
  def dirname, do: @dirname

  @doc "The config filename within the `.codex` directory (`config.toml`)."
  @spec filename() :: String.t()
  def filename, do: @filename
end
