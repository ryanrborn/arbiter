defmodule Arbiter.MCP.AgentConfig.Claude do
  @moduledoc """
  Claude Code's `Arbiter.MCP.AgentConfig` adapter (Phase 1).

  Writes a per-spawn `.mcp.json` into the worker's worktree declaring the
  Arbiter MCP server as a remote HTTP server with the spawn's scope token in a
  bearer header:

      {
        "mcpServers": {
          "arbiter": {
            "type": "http",
            "url": "http://127.0.0.1:4848/mcp",
            "headers": { "Authorization": "Bearer <scope-token>" }
          }
        }
      }

  Claude Code auto-loads `.mcp.json` from the working directory. (Known cosmetic
  quirk: the `/mcp` dialog shows header-bearer HTTP servers as "not
  authenticated" even when the token works — the auth indicator only tracks
  OAuth state. The connection and tool calls still authenticate.)
  """

  @behaviour Arbiter.MCP.AgentConfig

  @filename ".mcp.json"

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    config = config_map(opts)
    File.write(Path.join(worktree, @filename), Jason.encode!(config, pretty: true))
  end

  @doc """
  The `.mcp.json` content as a (string-keyed) map. Exposed for tests / inspection.
  Requires `:mcp_url` and `:scope_token`; `:server_name` defaults to `"arbiter"`.
  """
  @spec config_map(keyword()) :: map()
  def config_map(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")

    %{
      "mcpServers" => %{
        name => %{
          "type" => "http",
          "url" => url,
          "headers" => %{"Authorization" => "Bearer " <> token}
        }
      }
    }
  end

  @doc "The config filename written into the worktree (`.mcp.json`)."
  @spec filename() :: String.t()
  def filename, do: @filename
end
