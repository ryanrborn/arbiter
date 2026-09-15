defmodule Arbiter.Sessions.Provider.ClaudeCode do
  @moduledoc """
  Claude Code as a session provider (bd-bpt0ag) — the first
  `Arbiter.Sessions.Provider` implementation.

  ## The pane runs the provisioned launch wrapper (phase 3)

  `command/1` returns `<sessions_root>/<id>/launch.sh`, the wrapper
  `Arbiter.Sessions.Provisioning` generated — **not** a bare `claude`
  invocation. That indirection is the §10.3 rule made structural: the wrapper
  sources a mode-`0600` env file for mode A's OAuth token, so no credential is
  ever an argv token on a host where `/proc/<pid>/cmdline` is world-readable.
  It also exports the session env itself, which means a pane whose tmux server
  was already running (and therefore ignored `tmux -e`) still gets it.

  When a session has **not** been provisioned — the phase-1 shape, still
  reachable via `launch(provision: false)` — `command/1` falls back to an
  interactive shell. §9.2 measured that a fresh `CLAUDE_CONFIG_DIR` blocks on
  three interactive gates before the agent is usable, so launching `claude`
  into an unprovisioned pane would hang forever with nobody to click through: a
  session that looks alive, bills nothing, and does nothing. A shell is the
  honest payload for a scaffold-less session.

  `config :arbiter, :sessions_launch_command, "sh -c '…'"` overrides both, which
  is how the live-systemd integration test pins a deterministic,
  quickly-observable payload.

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

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session

  @fallback_shell "/bin/sh"

  @impl Arbiter.Sessions.Provider
  def command(%Session{} = session) do
    Application.get_env(:arbiter, :sessions_launch_command) || payload(session)
  end

  @impl Arbiter.Sessions.Provider
  def env(%Session{} = session) do
    ([{"ARB_SESSION_ID", session.id}] ++
       pair("CLAUDE_CONFIG_DIR", session.config_dir) ++
       pair("ARB_SESSION_ROOT", session.root_dir))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp payload(%Session{id: id}) do
    script = Layout.launch_script_path(id)

    if File.regular?(script), do: script, else: interactive_shell()
  end

  defp pair(_name, value) when value in [nil, ""], do: []
  defp pair(name, value), do: [{name, value}]

  # The operator's own shell, so an unprovisioned pane behaves like the terminal
  # it replaces.
  defp interactive_shell, do: System.get_env("SHELL") || @fallback_shell
end
