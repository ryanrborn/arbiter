defmodule Arbiter.Sessions.Layout do
  @moduledoc """
  The RFC §9.1 per-session directory tree, as pure path functions
  (bd-aprlbb, phase 3).

      <sessions_root>/<session-id>/
        workspace/            # cwd for the agent; git worktrees created here
        config/               # CLAUDE_CONFIG_DIR (isolated, per session)
        CLAUDE.md             # generated: role, workspace binding, guardrails
        .mcp.json             # per-session scope token (§9.3)
        memory/
          shared/             # read-only mounted layers (§9.4; phase 12 fills)
          candidates/         # per-session write space (§9.4)
        transcript/           # raw PTY byte stream (§11)
        auth.env              # mode 0600, mode-A only (§10.3)
        launch.sh             # mode 0700 wrapper; the only argv token

  Kept separate from `Arbiter.Sessions.Provisioning` for the same reason
  `Arbiter.Sessions.Naming` is separate from the launcher: the mapping from a
  session id to its on-disk handles is a pure function, so the adoption sweep,
  a `doctor` check and a test can all ask where something *should* be without
  creating anything.

  ## §10.2 layer 1 lives here

  "Scaffold, never point at a checkout" (decision 4) is only true if the
  scaffold is genuinely elsewhere. `outside_primary_checkout?/1` is the
  assertion of that, and `Arbiter.Sessions.Provisioning` refuses to provision
  when it is false — so a misconfigured `ARBITER_SESSIONS_ROOT` pointing into
  the live source tree fails loudly at provision time rather than handing an
  agent a cwd Phoenix hot-reload is watching.
  """

  alias Arbiter.Config.Paths

  @doc "Root holding every session scaffold (`Arbiter.Config.Paths.sessions_root/0`)."
  @spec root() :: String.t()
  def root, do: Path.expand(Paths.sessions_root())

  @doc "A session's own directory, `<sessions_root>/<session-id>`."
  @spec session_dir(String.t()) :: String.t()
  def session_dir(id) when is_binary(id), do: Path.join(root(), id)

  @doc "The agent's working directory — never an existing checkout (§10.2 layer 1)."
  @spec workspace_dir(String.t()) :: String.t()
  def workspace_dir(id), do: Path.join(session_dir(id), "workspace")

  @doc "The session's isolated `CLAUDE_CONFIG_DIR`."
  @spec config_dir(String.t()) :: String.t()
  def config_dir(id), do: Path.join(session_dir(id), "config")

  @doc "The generated coordinator instructions (§9.1, and §10.2 layer 4)."
  @spec instructions_path(String.t()) :: String.t()
  def instructions_path(id), do: Path.join(session_dir(id), "CLAUDE.md")

  @doc "The per-session `.mcp.json` (§9.3). Written mode 0600 — it holds a bearer token."
  @spec mcp_config_path(String.t()) :: String.t()
  def mcp_config_path(id), do: Path.join(session_dir(id), ".mcp.json")

  @doc "Memory mount root (§9.4)."
  @spec memory_dir(String.t()) :: String.t()
  def memory_dir(id), do: Path.join(session_dir(id), "memory")

  @doc "Read-only shared memory layers; phase 12 mounts them, phase 3 only makes the point."
  @spec memory_shared_dir(String.t()) :: String.t()
  def memory_shared_dir(id), do: Path.join(memory_dir(id), "shared")

  @doc "Per-session candidate memory space — the only place a session writes memory (§9.4)."
  @spec memory_candidates_dir(String.t()) :: String.t()
  def memory_candidates_dir(id), do: Path.join(memory_dir(id), "candidates")

  @doc "Raw PTY byte stream (§11); phase 11 fills it."
  @spec transcript_dir(String.t()) :: String.t()
  def transcript_dir(id), do: Path.join(session_dir(id), "transcript")

  @doc """
  The mode-`0600` env file the launch wrapper sources (§10.3).

  Mode A's `CLAUDE_CODE_OAUTH_TOKEN` goes here and **never** into argv:
  `/proc/<pid>/cmdline` is world-readable on this host and the session's
  command line is a `tmux -e` list.
  """
  @spec auth_env_path(String.t()) :: String.t()
  def auth_env_path(id), do: Path.join(session_dir(id), "auth.env")

  @doc """
  The launch wrapper tmux runs — the session's single argv token.

  A wrapper rather than a direct `claude …` invocation precisely so the
  credential can be a file read at exec time instead of a flag (§10.3).
  """
  @spec launch_script_path(String.t()) :: String.t()
  def launch_script_path(id), do: Path.join(session_dir(id), "launch.sh")

  @doc "Every directory `Arbiter.Sessions.Provisioning` creates, in creation order."
  @spec directories(String.t()) :: [String.t()]
  def directories(id) do
    [
      session_dir(id),
      workspace_dir(id),
      config_dir(id),
      memory_dir(id),
      memory_shared_dir(id),
      memory_candidates_dir(id),
      transcript_dir(id)
    ]
  end

  @doc "Every path in the §9.1 tree, as a map. Handy for tests and a `doctor` check."
  @spec paths(String.t()) :: %{atom() => String.t()}
  def paths(id) do
    %{
      root: session_dir(id),
      workspace: workspace_dir(id),
      config: config_dir(id),
      instructions: instructions_path(id),
      mcp_config: mcp_config_path(id),
      memory: memory_dir(id),
      memory_shared: memory_shared_dir(id),
      memory_candidates: memory_candidates_dir(id),
      transcript: transcript_dir(id),
      auth_env: auth_env_path(id),
      launch_script: launch_script_path(id)
    }
  end

  @doc """
  Whether `path` is safely outside the primary checkout (§10.2 layer 1).

  `nil` for the checkout means it could not be resolved, and the answer is
  `true` — the guard is inactive, which matches `build-local-release.sh`'s
  behaviour of warning rather than refusing when the checkout is unknown.
  Comparison is on expanded paths with a trailing separator so a sibling
  directory whose name merely *starts* with the checkout path
  (`/home/ryan/dev/arbiter-sessions` vs `/home/ryan/dev/arbiter`) is not
  mistaken for a child.
  """
  @spec outside_primary_checkout?(String.t(), String.t() | nil) :: boolean()
  def outside_primary_checkout?(path, checkout \\ nil)

  def outside_primary_checkout?(path, nil) when is_binary(path) do
    case Paths.primary_checkout() do
      nil -> true
      checkout -> outside?(path, checkout)
    end
  end

  def outside_primary_checkout?(path, checkout) when is_binary(path) and is_binary(checkout),
    do: outside?(path, checkout)

  defp outside?(path, checkout) do
    expanded = Path.expand(path)
    root = Path.expand(checkout)

    expanded != root and not String.starts_with?(expanded, root <> "/")
  end
end
