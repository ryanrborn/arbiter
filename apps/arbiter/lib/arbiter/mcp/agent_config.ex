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
  MCP config rather than failing the dispatch.
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

  Also writes the injected paths to the worktree's `.git/info/exclude` so that
  `git add -A` / `git add .` in the target repo cannot sweep the token-bearing
  config file into a commit, regardless of the target repo's `.gitignore`
  (bd-9q966y). Best-effort: a missing git repo or unwritable info dir never blocks
  the spawn.
  """
  @spec write(atom() | String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def write(provider, worktree, opts) do
    case adapter_for(provider) do
      nil ->
        :ok

      mod ->
        case mod.write_mcp_config(worktree, opts) do
          :ok ->
            if function_exported?(mod, :gitignore_paths, 0) do
              _ = add_to_git_exclude(worktree, mod.gitignore_paths())
            end

            :ok

          err ->
            err
        end
    end
  end

  # ---- Git exclude ---------------------------------------------------------

  # Append `paths` to the worktree's `.git/info/exclude` file so that `git add -A`
  # cannot stage token-bearing agent config regardless of the target repo's tracked
  # `.gitignore`. The info/exclude is local to the worktree — it is NOT committed —
  # so it works on any contributor repo without touching the repo's own gitignore.
  #
  # `git rev-parse --git-dir` returns the worktree's git dir. For a linked worktree
  # this is `.git/worktrees/<leaf>` (relative to the main repo); for a plain clone
  # it's `.git`. We resolve it to an absolute path so File.write/mkdir_p work
  # regardless of cwd.
  #
  # Best-effort: any error is silently swallowed — a missing git repo or a
  # read-only info dir must never block a dispatch.
  @spec add_to_git_exclude(Path.t(), [String.t()]) :: :ok
  def add_to_git_exclude(worktree, paths) when is_binary(worktree) and is_list(paths) do
    case System.cmd("git", ["-C", worktree, "rev-parse", "--git-dir"], stderr_to_stdout: true) do
      {raw, 0} ->
        git_dir = String.trim(raw)

        git_dir =
          if Path.type(git_dir) == :absolute,
            do: git_dir,
            else: Path.expand(git_dir, worktree)

        info_dir = Path.join(git_dir, "info")
        exclude_path = Path.join(info_dir, "exclude")

        with :ok <- File.mkdir_p(info_dir) do
          existing = if File.exists?(exclude_path), do: File.read!(exclude_path), else: ""

          new_entries =
            paths
            |> Enum.reject(fn p -> existing =~ p end)
            |> Enum.join("\n")

          if new_entries != "" do
            separator = if String.ends_with?(existing, "\n") or existing == "", do: "", else: "\n"
            File.write!(exclude_path, existing <> separator <> new_entries <> "\n")
          end
        end

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
