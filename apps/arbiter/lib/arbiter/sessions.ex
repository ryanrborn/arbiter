defmodule Arbiter.Sessions do
  @moduledoc """
  Ash domain + lifecycle API for browser-hosted coordinator sessions
  (`docs/browser-hosted-coordinator-sessions.md`, phase 1 / bd-bpt0ag).

  ## The one load-bearing property

  **Arbiter holds no long-lived handle to the PTY.** Not a `Port`, not a pid,
  not a file descriptor, not a linked process. A session is launched as

      systemd-run --user --scope --unit=arb-session-<id> --collect \\
        tmux -S $XDG_RUNTIME_DIR/arbiter/session-<id>.sock \\
             new-session -d -s coord -x <cols> -y <rows> -e … "<agent command>"

  and from then on every control operation — kill, enumerate, adopt — shells
  out to `tmux` or `systemctl --user` and exits. The session's processes live
  in a transient systemd **scope**, which is a *sibling* cgroup of
  `arbiter.service`, so `systemctl --user restart arbiter` cannot reach them
  (§4.1: `arbiter.service` has no `KillMode`, so systemd's default
  `KillMode=control-group` signals every process in the unit's cgroup — and
  `setsid`, daemonising and double-forking do **not** move a process between
  cgroups, which is why the intuitive "detach it" answer was measured dead).

  Restart survival is therefore true *by construction* rather than by careful
  coding: there is no supervision link to sever. `Arbiter.Sessions.Adoption`
  rediscovers sessions after a restart by listing scope units and sockets.

  ## API

    * `launch/1` — create the row, then start the scope. Returns the row with
      `status: :running`.
    * `list/0,1` — every session, newest first; `list(status: :running)` for the
      live ones.
    * `get/1` — one session by id.
    * `kill/2` — tmux `kill-session` then `systemctl --user stop` the scope, and
      record `ended_at` + a reason. Refuses to kill the **caller's own** session
      (§10.1; see `Arbiter.Sessions.Guards`).
    * `usage_events/1` — the ledger rows attributable to a session, joined by
      string on the *provider* session id (§7.4 item 4).

  ## Phase 1 boundaries

  Provisioning (`CLAUDE_CONFIG_DIR` seeding, `.mcp.json`, credentials), the
  browser transport and UI, and Remote Control are later phases. Until
  provisioning exists, `Arbiter.Sessions.Provider.ClaudeCode` launches an
  interactive **shell** in the pane rather than `claude` — the RFC's phase-1
  scope explicitly allows a trivial payload, and launching a real agent with
  an unseeded config dir would only hang on the three interactive onboarding
  gates §9.2 documents.

  ## Secrets

  Nothing secret goes on a command line. `/proc/<pid>/cmdline` is world-readable
  on this host and this repo has an incident class around exactly that (§10.3),
  so the only env reaching the pane through `tmux -e` is non-secret
  (`ARB_SESSION_ID`, `CLAUDE_CONFIG_DIR`). Credentials arrive via the session's
  config dir in phase 3, never as an argv token.
  """

  use Ash.Domain

  alias Arbiter.Sessions.Guards
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Provider
  alias Arbiter.Sessions.Runner
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Terminal
  alias Arbiter.Usage.Event

  require Ash.Query
  require Logger

  resources do
    resource Arbiter.Sessions.Session
  end

  @default_cols 200
  @default_rows 50

  @type launch_opts :: [
          provider: atom(),
          workspace_id: String.t() | nil,
          config_dir: String.t() | nil,
          cwd: String.t(),
          auth_mode: atom(),
          remote_control: boolean(),
          cols: pos_integer(),
          rows: pos_integer(),
          runner: module()
        ]

  @doc """
  Launch a session: write the row, then start its systemd scope.

  The row comes first because the scope's *name* is derived from the session id
  (`Arbiter.Sessions.Naming`) — so a scope can never exist that no row points
  at, which is the invariant the adoption sweep relies on to tell "mine" from
  "somebody else's". A launch that fails leaves the row behind marked `:ended`
  with the failure as its reason, rather than deleting it: a failed launch is
  something an operator wants to see, and the sweep must not confuse it with a
  live session.

  ## Options

    * `:cwd` — the agent's working directory. Required.
    * `:provider` — default `:claude_code`.
    * `:workspace_id` — `nil` (default) means cross-workspace.
    * `:config_dir` — the session's `CLAUDE_CONFIG_DIR`; `nil` in phase 1.
    * `:auth_mode` — `:seeded_credentials` (default, mode B) or `:oauth_token`.
    * `:remote_control` — recorded only in phase 1.
    * `:cols` / `:rows` — initial pane geometry (default #{@default_cols}x#{@default_rows}).
    * `:runner` — command runner module, for tests. See `Arbiter.Sessions.Runner`.
  """
  @spec launch(launch_opts()) :: {:ok, Session.t()} | {:error, term()}
  def launch(opts \\ []) do
    with {:ok, cwd} <- fetch_cwd(opts),
         {:ok, socket_dir} <- Naming.socket_dir(),
         :ok <- ensure_socket_dir(socket_dir),
         {:ok, session} <- create_row(cwd, opts) do
      start_scope(session, opts)
    end
  end

  @doc "Every session, newest first. `list(status: :running)` filters by status."
  @spec list(keyword()) :: [Session.t()]
  def list(opts \\ []) do
    query = Ash.Query.sort(Session, started_at: :desc)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> Ash.Query.filter(query, status == ^status)
      end

    Ash.read!(query)
  end

  @doc "One session by id."
  @spec get(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Ash.get(Session, id) do
      {:ok, session} -> {:ok, session}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Kill a session: `tmux kill-session`, then stop the scope, then record the end.

  ## Options

    * `:caller_session_id` — the session id of the *caller*, when the call
      arrives from inside a session (its scope exports `ARB_SESSION_ID`).
      Killing your own session is refused — it would terminate the caller
      mid-call (§10.1). Pass `nil`/omit for an operator-originated kill.
    * `:reason` — recorded in `end_reason`. Defaults to `"killed"`.
    * `:runner` — command runner module, for tests.

  Both commands are best-effort and by **exact** name: a session whose tmux
  server is already gone still gets its scope stopped and its row ended, so a
  half-dead session can always be cleaned up. Never a pattern-matching kill —
  the unit name and socket path are exact strings derived from the id.
  """
  @spec kill(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def kill(id, opts \\ []) when is_binary(id) do
    with :ok <- Guards.check_self_kill(id, Keyword.get(opts, :caller_session_id)),
         {:ok, session} <- get(id) do
      runner = runner(opts)

      run(runner, "tmux", ["-S", session.tmux_socket, "kill-session", "-t", Naming.tmux_session()])

      run(runner, "systemctl", ["--user", "stop", session.scope_unit])

      mark_ended(session, Keyword.get(opts, :reason, "killed"))
    end
  end

  @doc """
  Mark a session ended, recording why (§4.6 requires the reason).

  Idempotent — re-ending an already-ended row keeps its original `ended_at`.
  """
  @spec mark_ended(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_ended(%Session{} = session, reason) when is_binary(reason) do
    Ash.update(session, %{end_reason: reason}, action: :mark_ended)
  end

  @doc "Mark a session's scope confirmed live (launch, or re-adoption)."
  @spec mark_running(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_running(%Session{} = session), do: Ash.update(session, %{}, action: :mark_running)

  @doc """
  Record a rollover onto a new provider-side session id (§7.5).

  A long session that hits `--resume` or compaction moves onto a new
  `<sid>.jsonl`, and the ledger is keyed on that string — so the row has to
  track the *current* id, not the one it launched with.
  """
  @spec record_provider_session(Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def record_provider_session(%Session{} = session, provider_session_id)
      when is_binary(provider_session_id) do
    Ash.update(session, %{provider_session_id: provider_session_id},
      action: :record_provider_session
    )
  end

  @doc "Note that a client is attached — the idle-deadline input (§4.6 item 2)."
  @spec touch_client(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def touch_client(%Session{} = session), do: Ash.update(session, %{}, action: :touch_client)

  @doc """
  The usage-ledger rows attributable to a session, oldest first.

  Joined **by string** on the provider session id, not by foreign key (§7.4
  item 4: "`Usage.Event` references it by the existing `session_id` string; no
  FK churn"). That is the id `Arbiter.Sessions.UsageIngest` already stamps on
  every `source: :coordinator_session` row it writes, so the rows the metering
  phase has been writing since bd-be804c join to a session row the moment one
  exists for them.

  Returns `[]` for a session that has not yet been assigned a provider session
  id — with no key there is nothing to join on, which is not the same as "no
  spend", and phase 7's HUD is where that distinction gets surfaced.
  """
  @spec usage_events(Session.t() | String.t() | nil) :: [Event.t()]
  def usage_events(%Session{provider_session_id: sid}), do: usage_events(sid)
  def usage_events(nil), do: []

  def usage_events(provider_session_id) when is_binary(provider_session_id) do
    Event
    |> Ash.Query.filter(session_id == ^provider_session_id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!()
  end

  @doc """
  The PubSub topic a session's live `usage` events are published on (§7.5).

  Phase 4 wires the **transport** for the HUD feed — `ArbiterWeb.SessionChannel`
  subscribes on join and forwards anything published here as a `usage` event —
  without deciding what goes in it. Phase 7 is the producer; until then the
  topic simply has no publisher, which is the cheapest possible placeholder.
  """
  @spec usage_topic(String.t()) :: String.t()
  def usage_topic(session_id) when is_binary(session_id), do: "session_usage:" <> session_id

  @doc "Publish a live usage payload to a session's attached clients (§7.5)."
  @spec broadcast_usage(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_usage(session_id, payload) when is_binary(session_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      usage_topic(session_id),
      {:session_usage, session_id, payload}
    )
  end

  @doc """
  The command runner module in force: `:runner` option, then application
  config, then the real one.
  """
  @spec runner(keyword()) :: module()
  def runner(opts \\ []) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:arbiter, :sessions_runner) ||
      Runner.Host
  end

  @doc """
  The terminal back end in force: `:terminal` option, then application config,
  then the real one (phase 4 — `Arbiter.Sessions.Terminal`).

  Same resolution order as `runner/1`, and the same purpose: the transport is
  tested headlessly against a scripted PTY rather than a tmux server.
  """
  @spec terminal(keyword()) :: module()
  def terminal(opts \\ []) do
    Keyword.get(opts, :terminal) ||
      Application.get_env(:arbiter, :sessions_terminal) ||
      Terminal.Tmux
  end

  # -- launch internals -------------------------------------------------------

  defp fetch_cwd(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, :cwd_required}
    end
  end

  defp ensure_socket_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:socket_dir_unavailable, dir, reason}}
    end
  end

  defp create_row(cwd, opts) do
    Ash.create(Session, %{
      provider: Keyword.get(opts, :provider, :claude_code),
      workspace_id: Keyword.get(opts, :workspace_id),
      config_dir: Keyword.get(opts, :config_dir),
      cwd: cwd,
      auth_mode: Keyword.get(opts, :auth_mode, :seeded_credentials),
      remote_control: Keyword.get(opts, :remote_control, false)
    })
  end

  defp start_scope(session, opts) do
    {command, args} = launch_argv(session, opts)

    case run(runner(opts), command, args, env: Provider.env(session)) do
      {_out, 0} ->
        mark_running(session)

      {out, status} ->
        reason = "launch failed (#{command} exited #{status}): #{summarize(out)}"
        Logger.error("Arbiter.Sessions.launch/1 #{session.id}: #{reason}")
        _ = mark_ended(session, reason)
        {:error, {:launch_failed, status, out}}
    end
  end

  @doc """
  The exact argv `launch/1` spawns — RFC §4.3's shape, verbatim.

  Public so a test can assert the command shape without launching anything,
  and so `arb`/the dashboard can *show* an operator what would run.
  """
  @spec launch_argv(Session.t(), keyword()) :: {String.t(), [String.t()]}
  def launch_argv(%Session{} = session, opts \\ []) do
    cols = Keyword.get(opts, :cols, @default_cols)
    rows = Keyword.get(opts, :rows, @default_rows)

    env_args =
      session
      |> Provider.env()
      |> Enum.flat_map(fn {name, value} -> ["-e", "#{name}=#{value}"] end)

    args =
      [
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--unit=#{Naming.unit_arg(session.id)}",
        "tmux",
        "-S",
        session.tmux_socket,
        "new-session",
        "-d",
        "-s",
        Naming.tmux_session(),
        "-x",
        to_string(cols),
        "-y",
        to_string(rows),
        "-c",
        session.cwd
      ] ++ env_args ++ [Provider.command(session)]

    {"systemd-run", args}
  end

  defp run(runner, command, args, opts \\ []) do
    runner.run(command, args, Keyword.put_new(opts, :stderr_to_stdout, true))
  end

  defp summarize(out) when is_binary(out) do
    out |> String.trim() |> String.split("\n") |> Enum.take(3) |> Enum.join(" / ")
  end

  defp summarize(out), do: inspect(out)
end
