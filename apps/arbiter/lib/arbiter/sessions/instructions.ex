defmodule Arbiter.Sessions.Instructions do
  @moduledoc """
  The generated `CLAUDE.md` a provisioned session boots with (bd-aprlbb,
  RFC §9.1 — "generated: role, workspace binding, guardrails").

  This is **§10.2 layer 4**, "belt and braces": the RFC's own note is that the
  dispatched-worker prompt already carries the live-checkout warning and it
  demonstrably helps. It is the weakest of the four layers on its own and the
  only one that reaches a session *before* it acts, which is why it ships
  alongside the other three rather than instead of them.

  It also carries the §9.4 memory doctrine, because the read-only convention on
  the shared layer is enforced by this file and nothing else: symlinked layers
  are writable by the user the session runs as, so "a session never writes into
  the shared layer" is a rule the agent follows, not a permission it lacks.

  Deliberately **not** shared with `ArbiterCli.Cmd.Init`'s templates. Those are
  compiled into the escript (`apps/arbiter_cli`), which the server app does not
  and must not depend on; and they scaffold an operator's coordinator *home*,
  which is a durable, hand-edited directory — not a per-session dir that is
  regenerated on every launch.
  """

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session

  @doc """
  Render the instructions for a session.

  ## Options

    * `:primary_checkout` — the live source tree to warn about; `nil` omits the
      warning rather than printing a placeholder path (an invented path is
      worse than no rule).
    * `:mcp_server_name` — the `.mcp.json` server key, default `"arbiter"`.
    * `:can_dispatch` — overrides the session row's value, for rendering a
      preview before the row exists.
  """
  @spec render(Session.t(), keyword()) :: String.t()
  def render(%Session{} = session, opts \\ []) do
    id = session.id
    paths = Layout.paths(id)
    can_dispatch = Keyword.get(opts, :can_dispatch, session.can_dispatch)
    server = Keyword.get(opts, :mcp_server_name, "arbiter")

    """
    # Arbiter coordinator session `#{id}`

    You are a **coordinator session**: an interactive Claude Code session that
    Arbiter provisioned and launched into a tmux pane, reachable from the
    Arbiter dashboard in a browser. You are not a dispatched worker and you have
    no single assigned task. You drive the fleet.

    This file is **generated on every launch** — edits to it are lost. Durable
    notes go in `memory/candidates/` (see "Memory", below).

    ## Your workspace

    #{workspace_section(session)}

    Your working directory is `#{paths.workspace}`. It is a fresh, empty
    directory that Arbiter created for this session — deliberately **not** a
    checkout of anything.

    #{checkout_section(Keyword.get(opts, :primary_checkout, default_checkout()))}

    ## Talking to Arbiter

    `#{paths.mcp_config}` registers the Arbiter MCP server (`#{server}`) with a
    bearer token minted for **this session only**. It is revoked the moment the
    session ends or is killed, so a copy of it is worth nothing afterwards —
    but it is a live credential while you run: never paste it into a file, a
    commit, a PR body, or your own output.

    #{dispatch_section(can_dispatch)}

    You cannot kill your own session through Arbiter's API — the call would
    terminate you mid-call. Ask the operator to kill it from the dashboard or
    the CLI.

    ## Memory

    * `memory/shared/` — the operator's memory layers, mounted **read-only**.
      Read them freely. **Never write, edit, or delete anything under it.**
      `MEMORY.md` is a single unlocked file and other sessions are reading it
      concurrently; a write from here is a last-write-wins clobber of somebody
      else's memory.
    * `memory/candidates/` — your write space. Anything you learn that is worth
      keeping goes here, one fact per file. A later promotion step (not yours)
      reviews candidates into the shared layer.

    ## Process discipline

    Never use `pkill`, `killall`, `fuser -k`, or any other name- or
    pattern-matching kill. Process command lines are visible host-wide: a
    pattern that matches your own process matches the live Arbiter server and
    every running worker just as easily. Capture an exact PID and kill that.
    """
  end

  defp workspace_section(%Session{workspace_id: nil}) do
    """
    This session is **cross-workspace**: its Arbiter token is not bound to one
    workspace, so tools that take a workspace need you to name it explicitly.
    """
    |> String.trim()
  end

  defp workspace_section(%Session{workspace_id: id}) do
    """
    This session is **bound to workspace `#{id}`**. Its Arbiter token cannot
    reach any other workspace; a cross-workspace request comes back as
    not-found, not as a permission error.
    """
    |> String.trim()
  end

  defp checkout_section(nil) do
    """
    ### Repository work

    Do repository work in a **git worktree** created under this session
    directory — never directly in a shared checkout. That is the same
    discipline every dispatched worker follows.
    """
    |> String.trim()
  end

  defp checkout_section(checkout) do
    """
    ### The live checkout is off limits

    `#{checkout}` is the **primary checkout the running Arbiter server is
    serving from**. Writing there — even a half-saved file — is picked up by
    Phoenix hot-reload and can take down the live server, the coordinator, and
    every worker in flight. This has happened.

    * Do **not** edit, create, or delete files under `#{checkout}`.
    * Do **not** run `git` commands that write there (`checkout`, `reset`,
      `stash`, `worktree prune`, …). Reading is fine.
    * Repository work goes in a **git worktree created under this session
      directory** — the same discipline every dispatched worker follows:
      `git -C <clone> worktree add #{Path.join("<session-workspace>", "<branch>")} <branch>`.

    Your permissions deny writes under that path, but the deny list is a
    guardrail against accidents, not a sandbox: you run as the operator's user
    and can reach anything they can. The rule above is the actual boundary.
    """
    |> String.trim()
  end

  defp dispatch_section(true) do
    "Dispatching workers is **enabled** for this session, so a worker you " <>
      "dispatch can itself reach Arbiter. Watch for recursion."
  end

  defp dispatch_section(false) do
    "Dispatching workers is **disabled** for this session (the default). Ask " <>
      "the operator to relaunch with it enabled if you need it."
  end

  defp default_checkout, do: Arbiter.Config.Paths.primary_checkout()
end
