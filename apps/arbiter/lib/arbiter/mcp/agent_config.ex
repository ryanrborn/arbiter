defmodule Arbiter.MCP.AgentConfig do
  @moduledoc """
  The per-agent config-injection seam — the only agent-specific surface of
  `Arbiter.MCP`. The tools and scope model are written once; only the spawn-time
  config file differs per agent type.

  Each agent adapter implements `write_mcp_config/2`, emitting the right config
  file into the spawn's worktree, pointing at the same Arbiter MCP URL with the
  spawn's scope token. Phase 1 ships the Claude Code adapter
  (`Arbiter.MCP.AgentConfig.Claude`, a `.mcp.json`); Phase 3 adds Gemini and
  Codex.

  `opts` carries: `:mcp_url`, `:scope_token`, `:server_name`.

  Resolution is forward-safe: `write/3` for an unknown provider is a silent no-op,
  so a workspace routed to an agent without an adapter yet simply spawns without
  MCP config rather than failing the sling.
  """

  @callback write_mcp_config(worktree :: Path.t(), opts :: keyword()) :: :ok | {:error, term()}

  # Provider atom → adapter module. Phase 1: Claude. Phase 3: Gemini, Codex.
  @adapters %{
    claude: Arbiter.MCP.AgentConfig.Claude,
    gemini: Arbiter.MCP.AgentConfig.Gemini,
    codex: Arbiter.MCP.AgentConfig.Codex
  }

  @doc """
  Write the MCP config for `provider` into `worktree`. Returns `:ok` (including
  for an unknown provider, which is a no-op) or `{:error, reason}` if the adapter
  could not write its file.
  """
  @spec write(atom() | String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def write(provider, worktree, opts) do
    case adapter_for(provider) do
      nil -> :ok
      mod -> mod.write_mcp_config(worktree, opts)
    end
  end

  @doc "The adapter module for a provider atom/string, or `nil` if none is registered."
  @spec adapter_for(atom() | String.t() | nil) :: module() | nil
  def adapter_for(provider) when is_atom(provider) and not is_nil(provider),
    do: Map.get(@adapters, provider)

  def adapter_for(provider) when is_binary(provider) do
    adapter_for(safe_atom(provider))
  end

  def adapter_for(_), do: nil

  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
