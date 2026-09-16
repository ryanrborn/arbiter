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

  For the same reason it carries the **role** doctrine (bd-5v8f8l): a
  coordinator files bugs rather than fixing them, and delegates the digging.
  `Arbiter.Sessions.Guards` cannot help here even though it is the stronger
  layer. Its two predicates are about API calls a session makes *to Arbiter*
  (self-kill, restart budget), and the write this rule is about never reaches
  Arbiter at all — it is an editor touching a worktree under the session's own
  directory. That worktree is also exactly where a session legitimately works
  when the operator *has* asked it to make a change, so the offending write and
  the wanted write are the same write to the same path; the only thing
  separating them is whether the operator asked, which no path- or tool-scoped
  rule can observe. Hence prompt-only, placed early, and fenced by
  `Arbiter.Sessions.InstructionsTest` so it cannot silently go missing again
  the way it silently was missing.

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
    # The row's cwd wins where it is set — the agent is told where it actually
    # is, and where its `.mcp.json` actually sits (it lives in the cwd; see
    # `Arbiter.Sessions.Layout.mcp_config_path/1`).
    cwd = session.cwd || Layout.workspace_dir(id)
    mcp_config = Path.join(cwd, ".mcp.json")
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

    #{delegation_section(can_dispatch)}

    #{research_section(can_dispatch)}

    ## Your workspace

    #{workspace_section(session)}

    Your working directory is `#{cwd}`. It is a fresh directory that Arbiter
    created for this session — deliberately **not** a checkout of anything. The
    only thing in it is the `.mcp.json` below.

    #{checkout_section(Keyword.get(opts, :primary_checkout, default_checkout()))}

    ## Talking to Arbiter

    `#{mcp_config}` registers the Arbiter MCP server (`#{server}`) with a
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
    ### Repository work, if the operator asks for it

    You do not normally need a checkout at all: your output on a bug is a
    filed issue, not a patch (see "Your first move is to file it", above).
    Reading a repository to root-cause something is fine and needs no
    worktree.

    **When — and only when — the operator has asked you to make a change
    yourself**, that change goes in a **git worktree created under this
    session directory**, never directly in a shared checkout. Absent that
    ask, treat this section as not applying to you.
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
    * Do **not** run `mix` there — not `mix test`, not `mix compile`, not a
      `mix` alias. The running server owns that `_build`; a second `mix`
      fighting it for the directory has wedged this install before.

    Your permissions deny writes under that path, but the deny list is a
    guardrail against accidents, not a sandbox: you run as the operator's user
    and can reach anything they can. The rule above is the actual boundary.

    **Reading** `#{checkout}` is fine, and it is usually all an investigation
    needs. This rule and the file-it-don't-fix-it rule above are independent:
    staying out of the live checkout is not permission to implement the fix
    somewhere else instead.

    #### Worktrees — only when the operator has asked you to make the change

    This is a carve-out, not your standing workflow. If the operator has
    explicitly asked you to make a change yourself, work in a **git worktree
    created under this session directory**, cut from a clone that is **not**
    the live checkout above (the operator keeps one alongside it for exactly
    this; ask which if you do not know):

        git -C <non-live-clone> worktree add #{Path.join("<session-workspace>", "<branch>")} <branch>

    Nothing here is an invitation to go find a checkout on your own
    initiative. Without that explicit ask, an investigation ends at a filed
    ticket.
    """
    |> String.trim()
  end

  # bd-5v8f8l. The role inversion this guards against did not violate any rule
  # that existed: a session obeyed the live-checkout prohibition exactly, made
  # a legitimate worktree under its own session directory, and started
  # implementing — because the prompt described worktree mechanics as its
  # standing way of doing repository work and never named filing as the
  # alternative. The prompt layer has to carry this one: the offending write
  # and an operator-requested write are the same write to the same
  # session-owned path, so no path- or tool-scoped guard in
  # `Arbiter.Sessions.Guards` can tell them apart. Hence "early and
  # prominent" rather than "thorough but buried".
  defp delegation_section(can_dispatch) do
    """
    ## Your first move is to file it, not to fix it

    You route work; you do not do it. When you find a bug — or the operator
    reports one — what you produce is a **filed issue**, not a patch.
    Investigate it to root cause, write the evidence down, and stop before the
    edit.

    **This is not "don't look into it."** The investigation is the valuable
    half and you should do all of it:

    * reproduce the problem, read the code, and land on concrete `file:line`
      root-cause references;
    * a suggested implementation shape, and the design decisions whoever
      implements it will have to make;
    * acceptance criteria specific enough to act on.

    That write-up is what turns a report into a ticket someone can pick up.
    File it with `task_create` and put the investigation in the body.

    **Then stop.** Cutting a branch, creating a worktree, editing a file, or
    running a test suite against a fix are not yours. #{dispatch_tail(can_dispatch)}

    A hand-edit from here also has no pull request, so it is never reviewed —
    ReviewGate only sees work that arrives as a PR from a dispatched worker.

    ### Two carve-outs

    * **The operator can ask you to make a change directly.** If they have,
      do it — in a worktree, per "the live checkout is off limits" below. It
      is the *unasked-for* fix this rule forbids, not every edit you ever
      make.
    * **Coordinator-owned files are yours.** `memory/candidates/`, your own
      notes and `task_update_progress` notes, and scratch under this session
      directory you write freely, with no ticket and no ceremony. They are
      not "the code".
    """
    |> String.trim()
  end

  defp dispatch_tail(true) do
    "Dispatching is enabled for this session, so once the issue is filed you " <>
      "may hand it to a worker with `worker_dispatch` — which is still not " <>
      "you implementing it."
  end

  defp dispatch_tail(false) do
    "Dispatching workers is **disabled** for this session (the default), so " <>
      "promoting the issue and dispatching a worker are the operator's to do. " <>
      "Say the ticket is filed and ready, and leave it there. A closed " <>
      "dispatch route is not a reason to conclude that implementing it " <>
      "yourself is the only way left to help — it is not, and it is worse " <>
      "than filing."
  end

  # The second half of bd-5v8f8l: the file, silent on *how* to investigate,
  # left the session doing all the digging inline. Mirrors the operator's own
  # coordinator doc ("Research discipline: delegate the digging, keep the
  # judgment") so the two do not drift.
  defp research_section(can_dispatch) do
    """
    ## Research discipline: delegate the digging, keep the judgment

    Reading source, chasing logs, and tracing a report to its root cause
    belongs in a delegate rather than inline in your own context. The reason
    is what makes the rule stick: that raw tool output rarely turns out to be
    worth keeping, and every line of it inflates your context for the rest of
    your life — and you are a long-lived session, unlike a worker.

    * **Exploratory digging you need answered in this conversation** ("go read
      the code and report back") → a **host subagent / fork** (Claude Code's
      `Agent` tool; other hosts expose their own). It inherits your context,
      its raw output stays out of yours, and you stay responsive to the
      operator while it runs.
    * **Investigation substantial enough to need a durable, citable record** —
      recurring failures, "why does this keep happening", anything you will
      want to point at weeks from now → a **`task`-type Arbiter issue**. What
      makes that durable is the tracked issue: the findings land in
      `task_update_progress` notes and in the issue body, which are
      paper-trailed and survive you, and the run is addressable by its
      `run_id`. A fork's output exists only in a context window that is going
      to end.
      #{research_dispatch_tail(can_dispatch)}

    **Nothing compounds automatically.** Arbiter has no memory subsystem — no
    store one worker writes and a later worker reads back. Every worker starts
    cold from its issue and the repo. So a finding that should shape *future*
    work has to be put somewhere load-bearing by hand: the repo's `CLAUDE.md`
    for a repo convention, a skill for a general working practice, a follow-up
    issue for a concrete fix, or `memory/candidates/` for coordinator context.
    Filing an investigation is not the same as the project having learned from
    it.

    Delegating research does not make you a messenger. Prioritization, filing
    discipline, cross-workspace calls, and the actual back-and-forth with the
    operator on tradeoffs all stay with you. Only the file-reading and
    log-chasing legwork moves.
    """
    |> String.trim()
  end

  defp research_dispatch_tail(true) do
    "Dispatching is enabled here, so you can file that issue and start the " <>
      "worker yourself."
  end

  defp research_dispatch_tail(false) do
    "Dispatching is disabled for this session (the default), so that worker " <>
      "is not a route you can take: file the research issue and leave it for " <>
      "the operator to promote. Until they do, a fork is your way to an " <>
      "answer inside this conversation."
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
