defmodule Arbiter.Sessions.Provider do
  @moduledoc """
  Provider-agnostic launch payload for a session (bd-bpt0ag; RFC §5.4 —
  "staying provider-agnostic", decision 7).

  A session is a systemd scope holding a tmux server holding **some agent's**
  PTY. Everything about the scope and the tmux server is identical whatever
  runs in the pane, so the provider-specific part is small and lives behind
  this behaviour: the command tmux runs, and the environment that command
  needs.

  Claude Code is the first implementation (`Arbiter.Sessions.Provider.ClaudeCode`).
  Adding Codex or Gemini is an adapter plus one atom in
  `Arbiter.Sessions.Session.providers/0` — not a schema or lifecycle change.

  ## The env rule is part of the contract

  `c:env/1` may only return **non-secret** values. They become `tmux -e`
  arguments, i.e. argv tokens, and `/proc/<pid>/cmdline` is world-readable on
  this host — RFC §10.3 makes "never a secret on a command line" a hard rule,
  and this repo has a documented incident class around exactly that. A
  provider that needs a credential gets it from its per-session config dir
  (phase 3), never from here.
  """

  alias Arbiter.Sessions.Session

  @doc """
  The command tmux runs in the pane, as a single shell-command string.

  tmux hands it to `/bin/sh -c`, so it is one argv token to `tmux new-session`.
  """
  @callback command(Session.t()) :: String.t()

  @doc "Non-secret environment the pane needs. See the module's env rule."
  @callback env(Session.t()) :: [{String.t(), String.t()}]

  @adapters %{claude_code: Arbiter.Sessions.Provider.ClaudeCode}

  @doc "The adapter module for a session's provider."
  @spec adapter(Session.t() | atom()) :: module()
  def adapter(%Session{provider: provider}), do: adapter(provider)

  def adapter(provider) when is_atom(provider) do
    Map.get(@adapters, provider) ||
      raise ArgumentError,
            "no Arbiter.Sessions.Provider adapter for #{inspect(provider)} " <>
              "(known: #{inspect(Map.keys(@adapters))})"
  end

  @doc "Delegates to the session's adapter."
  @spec command(Session.t()) :: String.t()
  def command(%Session{} = session), do: adapter(session).command(session)

  @doc "Delegates to the session's adapter."
  @spec env(Session.t()) :: [{String.t(), String.t()}]
  def env(%Session{} = session), do: adapter(session).env(session)
end
