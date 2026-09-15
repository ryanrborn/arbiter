defmodule Arbiter.Sessions.Provider.ClaudeCode do
  @moduledoc """
  Claude Code as a session provider (bd-bpt0ag) — the first
  `Arbiter.Sessions.Provider` implementation.

  ## Phase 1 launches a shell, deliberately

  The RFC's phase-1 scope says the payload "may launch a trivial command (e.g.
  a shell) until provisioning (phase 3) exists", and that is not a shortcut —
  it is the only correct thing to do here. §9.2 measured that a fresh
  `CLAUDE_CONFIG_DIR` blocks on **three** interactive gates (theme picker,
  login-method wizard, folder-trust prompt) before the agent is usable. With no
  seeded `.claude.json` to answer them, launching `claude` in a detached pane
  would hang forever with nobody to click through — a session that looks alive,
  bills nothing, and does nothing. A shell, by contrast, gives phase 1 exactly
  what it needs to prove: a real PTY in a sibling cgroup that survives
  `systemctl --user restart arbiter`.

  So `command/1` returns an interactive shell, overridable with

      config :arbiter, :sessions_launch_command, "sh -c '…'"

  which is also how the live-systemd integration test pins a deterministic,
  quickly-observable payload. Phase 3 replaces the default with the real
  `claude` invocation once there is a provisioned config dir to point it at.

  ## Environment

  `CLAUDE_CONFIG_DIR` is the isolation mode B still provides (§8.2) and is what
  makes per-session metering work at all — the JSONL that
  `Arbiter.Sessions.UsageIngest` reads lives under it. `ARB_SESSION_ID` is how
  a session identifies *itself* to Arbiter's API, which is what the self-kill
  guard (§10.1) checks against.

  Neither is secret. Credentials are **not** here on purpose: mode A's
  `CLAUDE_CODE_OAUTH_TOKEN` and mode B's `.credentials.json` both reach the
  session through its config dir in phase 3, never as an argv token
  (§10.3).
  """

  @behaviour Arbiter.Sessions.Provider

  alias Arbiter.Sessions.Session

  @fallback_shell "/bin/sh"

  @impl Arbiter.Sessions.Provider
  def command(%Session{}) do
    Application.get_env(:arbiter, :sessions_launch_command) || interactive_shell()
  end

  @impl Arbiter.Sessions.Provider
  def env(%Session{} = session) do
    [{"ARB_SESSION_ID", session.id}] ++
      case session.config_dir do
        dir when is_binary(dir) and dir != "" -> [{"CLAUDE_CONFIG_DIR", dir}]
        _ -> []
      end
  end

  # The operator's own shell, so the pane behaves like the terminal it replaces.
  defp interactive_shell, do: System.get_env("SHELL") || @fallback_shell
end
