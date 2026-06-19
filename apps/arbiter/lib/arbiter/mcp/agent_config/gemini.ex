defmodule Arbiter.MCP.AgentConfig.Gemini do
  @moduledoc """
  Gemini CLI's `Arbiter.MCP.AgentConfig` adapter (Phase 3).

  Writes a per-spawn `.gemini/settings.json` into the acolyte's worktree,
  declaring the Arbiter MCP server as a remote HTTP server with the spawn's
  scope token in a bearer header:

      {
        "mcpServers": {
          "arbiter": {
            "httpUrl": "http://127.0.0.1:4848/mcp",
            "headers": { "Authorization": "Bearer <scope-token>" },
            "includeTools": ["bead_show", "bead_update_progress", ...]
          }
        }
      }

  The `includeTools` list is set to the polecat-tier tool set (all six tools
  the polecat scope can call). This is a *secondary* scope hook — the server
  enforces the polecat's capability via the signed token; `includeTools` acts
  as a belt-and-suspenders client-side allowlist so Gemini's tool-choice UI
  surfaces only the tools the polecat is permitted to call, and the
  most-restrictive-wins rule applies if the server ever exposes more.

  Coordinator-scope callers may pass `include_tools: nil` to disable the
  allowlist and expose all tools the token permits.
  """

  @behaviour Arbiter.MCP.AgentConfig

  @dirname ".gemini"
  @filename "settings.json"

  # The polecat-tier tool allowlist. Matches the tools that a :polecat scope
  # token is permitted to call (see Arbiter.MCP.Scope and the tool catalog in
  # docs/mcp-server-design.md §3).
  @polecat_tools ~w(
    bead_show
    bead_update_progress
    inbox_check
    message_send
    notify_list
    workspace_show
  )

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    dir = Path.join(worktree, @dirname)

    with :ok <- File.mkdir_p(dir),
         config = config_map(opts),
         :ok <- File.write(Path.join(dir, @filename), Jason.encode!(config, pretty: true)) do
      :ok
    end
  end

  @doc """
  The `.gemini/settings.json` content as a (string-keyed) map. Exposed for
  tests / inspection.

  Requires `:mcp_url` and `:scope_token`. Optional:
  - `:server_name` — defaults to `"arbiter"`.
  - `:include_tools` — a list of tool names to allowlist, or `:polecat` (the
    default) to use the built-in polecat-tier list, or `nil` to omit the key
    entirely (coordinator scope where all tools are permitted).
  """
  @spec config_map(keyword()) :: map()
  def config_map(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")
    include_tools = resolve_include_tools(opts)

    server =
      %{
        "httpUrl" => url,
        "headers" => %{"Authorization" => "Bearer " <> token}
      }
      |> maybe_put_include_tools(include_tools)

    %{"mcpServers" => %{name => server}}
  end

  @doc "The polecat-tier tool allowlist written into `includeTools`."
  @spec polecat_tools() :: [String.t()]
  def polecat_tools, do: @polecat_tools

  @doc "The config directory name written into the worktree (`.gemini`)."
  @spec dirname() :: String.t()
  def dirname, do: @dirname

  @doc "The config filename within the `.gemini` directory (`settings.json`)."
  @spec filename() :: String.t()
  def filename, do: @filename

  # ---- Internals -----------------------------------------------------------

  # :polecat (default) → the built-in polecat tool list
  # nil → omit includeTools entirely (coordinator scope)
  # a list → use as-is
  defp resolve_include_tools(opts) do
    case Keyword.get(opts, :include_tools, :polecat) do
      :polecat -> @polecat_tools
      nil -> nil
      tools when is_list(tools) -> tools
    end
  end

  defp maybe_put_include_tools(server, nil), do: server
  defp maybe_put_include_tools(server, tools), do: Map.put(server, "includeTools", tools)
end
