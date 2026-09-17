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

  ## Provisioning (phase 3)

  `launch/1` now **provisions before it launches**
  (`Arbiter.Sessions.Provisioning`): the §9.1 directory tree, an interactive
  `CLAUDE_CONFIG_DIR` with the three §9.2 onboarding gates pre-answered, a
  generated `CLAUDE.md`, and a `.mcp.json` carrying a per-session revocable
  coordinator token. A provisioning failure aborts the launch and ends the row
  — a session launched against an unseeded config dir does not fail, it hangs
  on a wizard nobody can click through.

  ## Phase boundaries

  The browser transport and UI, Remote Control, and the memory layers
  themselves are later phases; phase 3 leaves only the §9.4 mount points.

  ## Secrets

  Nothing secret goes on a command line. `/proc/<pid>/cmdline` is world-readable
  on this host and this repo has an incident class around exactly that (§10.3),
  so the only env reaching the pane through `tmux -e` is non-secret
  (`ARB_SESSION_ID`, `CLAUDE_CONFIG_DIR`). Mode A's OAuth token is written to a
  mode-`0600` file the launch wrapper sources; mode B's credential is a copy
  inside the session's config dir. Neither is ever an argv token, and neither
  is ever written to the row.
  """

  use Ash.Domain

  alias Arbiter.Sessions.BridgeVerification
  alias Arbiter.Sessions.Guards
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Provider
  alias Arbiter.Sessions.Provisioning
  alias Arbiter.Sessions.RepoCheckout
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
  @default_bridge_verify_timeout_ms 15_000
  @default_bridge_verify_poll_interval_ms 500

  @type launch_opts :: [
          provider: atom(),
          workspace_id: String.t() | nil,
          config_dir: String.t() | nil,
          cwd: String.t(),
          name: String.t() | nil,
          auth_mode: atom(),
          remote_control: boolean(),
          can_dispatch: boolean(),
          provision: boolean(),
          cols: pos_integer(),
          rows: pos_integer(),
          runner: module(),
          ensure_reader: boolean(),
          verify_bridge: boolean(),
          bridge_verify_fun: (String.t(), keyword() -> :ok | {:error, :bridge_unavailable}),
          bridge_verify_timeout_ms: pos_integer(),
          bridge_verify_poll_interval_ms: pos_integer()
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

    * `:cwd` — the agent's working directory. **Optional since phase 3**: the
      default is the scaffolded `<sessions_root>/<id>/workspace`, because
      decision 4 / §10.2 layer 1 is that a session is scaffolded rather than
      pointed at an existing checkout.
    * `:provider` — default `:claude_code`.
    * `:workspace_id` — `nil` (default) means cross-workspace.
    * `:issue_id` — binds the session to one issue, which makes it a **refine
      session** (bd-1lszsc): its MCP token is minted at the `:refine` tier
      bound to that issue rather than at the coordinator tier, and at most one
      live session may carry a given `issue_id`. Set by
      `Arbiter.Sessions.Refine.open/2`, which is the supported way in.
    * `:config_dir` — override the session's `CLAUDE_CONFIG_DIR`; defaults to
      the scaffolded one.
    * `:name` — an operator-supplied display name (bd-o2vtsz). Passed through
      as `claude --name`, shell-quoted, in the generated `launch.sh`
      (`Arbiter.Sessions.Provisioning`). `nil` (default) leaves `launch.sh`
      exec'ing a bare `claude`, unchanged from before this option existed.
    * `:auth_mode` — `:seeded_credentials` (default, mode B — Amendment 2) or
      `:oauth_token` (mode A).
    * `:can_dispatch` — default `false` (§10.1).
    * `:remote_control` — recorded; phase 8 acts on it.
    * `:provision` — `false` skips provisioning (the phase-1 shape, used by the
      lifecycle tests that assert only the command). Default `true`.
    * `:cols` / `:rows` — initial pane geometry (default #{@default_cols}x#{@default_rows}).
    * `:runner` — command runner module, for tests. See `Arbiter.Sessions.Runner`.
    * `:ensure_reader` — `false` skips the eager `Arbiter.Sessions.Stream.ensure_reader/2`
      call this function otherwise makes right after `mark_running/1` (§11's
      raw-transcript capture, bd-5pelo2 round 5 finding 1). Default `true`.
      A test that needs precise, deterministic control over exactly when and
      under what terminal the *first* `open_stream/1` happens — driving that
      race itself rather than racing an eager background start — wants
      `false` here (see `ArbiterWeb.SessionChannelTest`'s `on_start_stream`
      hook, which only fires once, on whichever call opens the reader first).
    * `:verify_bridge` — `false` skips the §8.3 bridge-verification poll this
      function otherwise starts (in the background, via `Arbiter.TaskSupervisor`)
      when `remote_control: true`. Default `true`. A row with `remote_control:
      false` never starts one regardless of this option — there is no bridge
      to verify.
    * `:bridge_verify_fun` — override for `Arbiter.Sessions.BridgeVerification.verify/2`,
      for tests that want to control the outcome without waiting on a poll.
    * `:bridge_verify_timeout_ms` / `:bridge_verify_poll_interval_ms` — passed
      straight through to the verifier (defaults
      #{@default_bridge_verify_timeout_ms}ms / #{@default_bridge_verify_poll_interval_ms}ms).
      A test asserting the timeout path wants both small.
  """
  @spec launch(launch_opts()) :: {:ok, Session.t()} | {:error, term()}
  def launch(opts \\ []) do
    with {:ok, socket_dir} <- Naming.socket_dir(),
         :ok <- ensure_socket_dir(socket_dir),
         {:ok, session} <- create_row(opts),
         {:ok, session} <- provision(session, opts) do
      start_scope(session, opts)
    end
  end

  # Provisioning failures end the row the same way a failed spawn does: an
  # operator wants to see *why* a launch never happened, and the adoption sweep
  # must not mistake a half-provisioned row for a live session.
  defp provision(session, opts) do
    if Keyword.get(opts, :provision, true) do
      case Provisioning.provision(session, opts) do
        {:ok, _provisioned} ->
          {:ok, session}

        {:error, reason} ->
          message = "provisioning failed: #{describe(reason)}"
          Logger.error("Arbiter.Sessions.launch/1 #{session.id}: #{message}")
          _ = mark_ended(session, message)
          {:error, {:provisioning_failed, reason}}
      end
    else
      {:ok, session}
    end
  end

  @doc """
  Mint this session's MCP scope token (§9.3).

  Coordinator tier, `can_dispatch` from the row (off by default), bound to the
  session's workspace or cross-workspace when it has none — and **revocable**:
  the token carries the session id, and `Arbiter.MCP.Scope.from_token/1`
  refuses it once the row is ended or revoked.
  """
  @spec mint_mcp_token(Session.t(), keyword()) :: String.t()
  defdelegate mint_mcp_token(session, opts \\ []), to: Provisioning, as: :mint_token

  @doc """
  Revoke the session's MCP token without ending the session (§9.3).

  Ending or killing a session revokes its token automatically; this is the
  leaked-token path, where the session itself is fine and only the credential
  needs replacing.
  """
  @spec revoke_mcp_token(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def revoke_mcp_token(%Session{} = session),
    do: Ash.update(session, %{}, action: :revoke_mcp_token)

  @doc """
  Whether the MCP token minted for `session_id` has been revoked (§9.3).

  `Arbiter.MCP.Scope.from_token/1` calls this for every token carrying a
  `session_id` claim. A session with **no row** is revoked: the row is the
  authority, and its absence cannot mean "allow".
  """
  @spec mcp_token_revoked?(String.t()) :: boolean()
  def mcp_token_revoked?(session_id) when is_binary(session_id) do
    case get(session_id) do
      {:ok, %Session{mcp_token_revoked_at: nil}} -> false
      {:ok, %Session{}} -> true
      {:error, :not_found} -> true
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

  Idempotent — re-ending an already-ended row keeps its original `ended_at`
  and `end_reason` (bd-bsdeb2: an exit racing an operator's Kill must not let
  the loser overwrite the winner's reason).

  Every path that ends a session — Kill, a payload exiting on its own, the
  adoption/orphan sweep finding a vanished scope — runs through here, so this
  is also the single place that tells `ArbiterWeb.SessionIndexLive` (and any
  other subscriber) to refresh (bd-bsdeb2, `lifecycle_topic/0`), and the
  single place that archives the session's own JSONL (§11, phase 9) — the
  CLI prunes its session store at ~21 days, so this is the last reliable
  moment to copy it out.

  It is also where a refine session's read-only repo checkout goes
  (bd-1lszsc). Putting it here rather than beside the Kill button is what
  makes "removed when the session ends" true for *every* way a session ends,
  including the ones nobody clicked: the idle reaper, the adoption sweep
  finding a vanished scope, and the agent simply exiting.
  """
  @spec mark_ended(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_ended(%Session{} = session, reason) when is_binary(reason) do
    # bd-bsdeb2: the caller's struct can be stale (e.g. the Stream's copy from
    # `init/1`, never refreshed). Re-read the persisted row first so the
    # idempotence guard in the `:mark_ended` action sees the *real* `ended_at`
    # — otherwise a stale "still running" struct lets a loser (an exit racing
    # an operator's Kill) overwrite the winner's `end_reason`/`ended_at`.
    current =
      case get(session.id) do
        {:ok, fresh} -> fresh
        {:error, :not_found} -> session
      end

    with {:ok, ended} <- Ash.update(current, %{end_reason: reason}, action: :mark_ended) do
      Phoenix.PubSub.broadcast(Arbiter.PubSub, lifecycle_topic(), {:session_ended, ended.id})
      _ = final_usage_ingest(ended)
      _ = archive_session_jsonl(ended)
      _ = purge_transcript_pipe(ended)
      _ = RepoCheckout.teardown(ended)
      {:ok, ended}
    end
  end

  # One last synchronous sweep of just this session's own JSONL (bd-9mrzti) —
  # the periodic `Arbiter.Sessions.UsageIngest` sweep only looks at non-ended
  # sessions, so without this a session's final turns (up to its
  # `interval_ms`) would sit unswept on a row nothing will read again, and
  # `/sessions` would show a stale total for an ended session forever.
  # Best-effort, same reasoning as `archive_session_jsonl/1`: a metering
  # hiccup must never block a session from ending.
  defp final_usage_ingest(%Session{} = session) do
    Arbiter.Sessions.UsageIngest.ingest(dirs: [], sessions: [session])
  rescue
    e ->
      Logger.warning(
        "Sessions.mark_ended: final usage ingest raised for #{session.id}: " <>
          Exception.message(e)
      )

      :ok
  end

  # Best-effort: `archive_session/4` already reduces every failure mode to
  # `{:ok, report}` (see its moduledoc), so this can only fail by raising,
  # which is exactly what the `rescue` is for — a session ending must never
  # be blocked by its own archival. Synchronous by design, not "never on the
  # caller's critical path" as an earlier revision of this comment claimed:
  # it runs inline inside `mark_ended/2`, which is on the Kill path, the
  # adoption/orphan sweeps, and (§11's own reader) `Stream`'s `:alive`
  # handler.
  defp archive_session_jsonl(%Session{} = session) do
    Arbiter.Worker.SessionArchive.archive_coordinator_session(session)
  rescue
    e ->
      Logger.warning(
        "Sessions.mark_ended: archive_coordinator_session raised for #{session.id}: " <>
          Exception.message(e)
      )

      :ok
  end

  # The tmux pipe file (`Naming.pipe_path/1`) lives on tmpfs and is no longer
  # closed when the last client detaches (`Stream`'s moduledoc, bd-5pelo2
  # finding 1) — nothing else deletes it once a session is truly over, so
  # without this it sits in RAM for the whole `TranscriptRetention` window
  # even though the durable, redacted `<id>.raw` already holds its content
  # (bd-5pelo2 round 5 finding 5). Safe here: every path that reaches
  # `mark_ended/2` (Kill, the `:alive` exit handler, the adoption/orphan
  # sweeps) has already established the pane's writer is gone before calling
  # it. Best-effort — a missing or unremovable file must never block the row
  # from ending.
  defp purge_transcript_pipe(%Session{id: id}) do
    case Naming.pipe_path(id) do
      {:ok, path} ->
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Sessions.mark_ended: pipe purge failed path=#{path}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  The PubSub topic session lifecycle changes (`mark_ended/2`, and
  `request_open/1`'s open request) are published on — the fleet-wide
  counterpart to `usage_topic/1`'s per-session one (bd-bsdeb2).
  """
  @spec lifecycle_topic() :: String.t()
  def lifecycle_topic, do: "sessions:lifecycle"

  @doc """
  Ask whatever session docks are listening to open `session_id` and expand it
  (bd-1lszsc).

  The dock is a **sticky nested LiveView** with its own process, and the pages
  that need to put something in it — the issue detail page's Refine button, the
  board card's — are separate processes holding no reference to it. A page
  cannot `send/2` the dock, and `send_update/2` is for LiveComponents, not
  LiveViews. So the request goes over the same lifecycle topic the dock is
  already subscribed to for its own reasons.

  Broadcast rather than addressed: the dashboard is loopback-only and
  single-operator (§10.4), so "every dock this operator has open" and "the dock
  that asked" differ only if they have two tabs up — in which case both showing
  the session they just asked for is the right answer, not a bug.

  Advisory, not a command. `ArbiterWeb.SessionDockLive` re-validates the id
  against the sessions that actually exist before opening anything, exactly as
  it does with the `localStorage` payload a browser hands it.
  """
  @spec request_open(String.t()) :: :ok | {:error, term()}
  def request_open(session_id) when is_binary(session_id) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      lifecycle_topic(),
      {:session_open_requested, session_id}
    )
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

  @doc "Note that a turn happened — the other idle-deadline input (§4.6 item 2, phase 10)."
  @spec touch_turn(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def touch_turn(%Session{} = session), do: Ash.update(session, %{}, action: :touch_turn)

  @doc """
  Pin (or unpin) a session against the idle-TTL sweep (§4.6 item 2, phase 10).

  A `keep_alive` session is never a candidate for `Arbiter.Sessions.IdleReaper`,
  however long it has gone without a client or a turn.
  """
  @spec set_keep_alive(Session.t(), boolean()) :: {:ok, Session.t()} | {:error, term()}
  def set_keep_alive(%Session{} = session, keep_alive?) when is_boolean(keep_alive?) do
    Ash.update(session, %{keep_alive: keep_alive?}, action: :set_keep_alive)
  end

  @doc """
  Change a session's operator-supplied display name (bd-o2vtsz).

  Arbiter-side only: a session already running keeps whatever `--name` gave it
  at launch (or none), because there is no safe way to rewrite a live
  session's own `sessions/<pid>.json` from outside — see the `name` attribute
  doc on `Arbiter.Sessions.Session`. `nil` clears an operator name, dropping
  display back to the `ai-title` rung of `Arbiter.Sessions.DisplayName`.
  """
  @spec rename(Session.t(), String.t() | nil) :: {:ok, Session.t()} | {:error, term()}
  def rename(%Session{} = session, name) when is_binary(name) or is_nil(name) do
    Ash.update(session, %{name: name}, action: :rename)
  end

  @doc """
  Persist that §8.3's bridge-verification poll never found a `bridge-session`
  record (bd-cdretj).

  `verify_bridge/2` already calls `broadcast_error/2` on this outcome, but
  that is fire-and-forget over `Phoenix.PubSub`: a session with no attached
  client at that moment never sees it, and the usual case is exactly that —
  verification runs in the ~15s right after launch, before an operator has
  opened the session. This gives a client that attaches *after* the fact
  something durable to check instead of a plain terminal indistinguishable
  from a healthy one.
  """
  @spec mark_bridge_unavailable(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_bridge_unavailable(%Session{} = session) do
    Ash.update(session, %{}, action: :mark_bridge_unavailable)
  end

  @doc """
  Clear a `bridge_status: :unavailable` once a `bridge-session` record is
  actually observed (bd-cdretj round 2) — an operator who fixed the bridge
  by hand after the fact (`/remote-control` retried in the session) leaves
  no other trace on this row, so the badge and list label would otherwise
  keep reporting a failure that already resolved itself.
  """
  @spec mark_bridge_available(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def mark_bridge_available(%Session{} = session) do
    Ash.update(session, %{}, action: :mark_bridge_available)
  end

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
  Publish an out-of-band error to a session's attached clients — currently
  just §8.3's `bridge_unavailable` (`verify_bridge/2`).

  On the same topic `broadcast_usage/2` uses: `usage_topic/1`'s doc already
  says it is "the transport for the HUD feed… without deciding what goes in
  it", and `ArbiterWeb.SessionChannel` already subscribes there on join, so a
  second producer needs no new subscription. `ArbiterWeb.SessionChannel`
  forwards this as the channel's own `error` event (`%{code, detail}`),
  which is the one already wired end-to-end to the terminal's error surface
  — no client-side change needed.

  A session with no attached client when this fires never sees it: there is
  nothing to persist to (§8.3's verification is a best-effort live signal),
  and an operator opening the session page later gets a working terminal —
  same as any other channel-only notification this transport already has.
  """
  @spec broadcast_error(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_error(session_id, payload) when is_binary(session_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      usage_topic(session_id),
      {:session_error, session_id, payload}
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

  defp ensure_socket_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:socket_dir_unavailable, dir, reason}}
    end
  end

  defp create_row(opts) do
    Ash.create(Session, %{
      provider: Keyword.get(opts, :provider, :claude_code),
      workspace_id: Keyword.get(opts, :workspace_id),
      issue_id: Keyword.get(opts, :issue_id),
      config_dir: Keyword.get(opts, :config_dir),
      cwd: Keyword.get(opts, :cwd),
      name: Keyword.get(opts, :name),
      auth_mode: Keyword.get(opts, :auth_mode, :seeded_credentials),
      remote_control: Keyword.get(opts, :remote_control, false),
      can_dispatch: Keyword.get(opts, :can_dispatch, false)
    })
  end

  defp start_scope(session, opts) do
    {command, args} = launch_argv(session, opts)

    case run(runner(opts), command, args, env: Provider.env(session)) do
      {_out, 0} ->
        with {:ok, running} <- mark_running(session) do
          # Starts §11's raw-transcript capture up front instead of waiting
          # on a browser's first `attach/2` — a session nobody ever opens
          # would otherwise never be captured at all (bd-5pelo2 round 5
          # finding 1). Fire-and-forget: `ensure_reader/2` logs and swallows
          # its own failures, and a session whose eager start failed still
          # gets a reader from the first real `attach/2`. Skippable via
          # `:ensure_reader` (see `launch/1`'s doc) for a test that needs to
          # drive the first `open_stream/1` itself.
          if Keyword.get(opts, :ensure_reader, true) do
            _ = Arbiter.Sessions.Stream.ensure_reader(running, opts)
          end

          if running.remote_control do
            verify_bridge(running, opts)
          end

          {:ok, running}
        end

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

  # §8.3 design consequence 2: never report "reachable remotely" on the
  # strength of having passed `--remote-control` — poll the JSONL for the
  # bridge-session record instead. Backgrounded so a launch that requested
  # Remote Control does not block the caller for up to
  # `:bridge_verify_timeout_ms`; `broadcast_error/2` is how the result reaches
  # an already-attached client, same transport `broadcast_usage/2` uses.
  defp verify_bridge(session, opts) do
    if Keyword.get(opts, :verify_bridge, true) do
      verify_fun = Keyword.get(opts, :bridge_verify_fun, &BridgeVerification.verify/2)

      # `:bridge_verify_timeout_ms` / `:bridge_verify_poll_interval_ms` fall
      # through to application config — same resolution `Provisioning`'s
      # `agent_command/2` uses for `:sessions_agent_command` — so a caller
      # that never sees `launch/1`'s opts (a LiveView `handle_event`) can
      # still pin this down for a test without threading options through it.
      verify_opts = [
        timeout_ms:
          Keyword.get(opts, :bridge_verify_timeout_ms) ||
            Application.get_env(
              :arbiter,
              :sessions_bridge_verify_timeout_ms,
              @default_bridge_verify_timeout_ms
            ),
        poll_interval_ms:
          Keyword.get(opts, :bridge_verify_poll_interval_ms) ||
            Application.get_env(
              :arbiter,
              :sessions_bridge_verify_poll_interval_ms,
              @default_bridge_verify_poll_interval_ms
            )
      ]

      Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn ->
        case verify_fun.(session.config_dir, verify_opts) do
          :ok ->
            :ok

          {:error, :bridge_unavailable} ->
            Logger.warning(
              "Arbiter.Sessions: remote control bridge never came up for #{session.id}"
            )

            case mark_bridge_unavailable(session) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "Arbiter.Sessions: could not persist bridge_status for #{session.id}: #{inspect(reason)}"
                )
            end

            broadcast_error(session.id, %{
              code: "bridge_unavailable",
              detail: "no bridge-session record within #{verify_opts[:timeout_ms]}ms"
            })
        end
      end)
    end

    :ok
  end

  defp summarize(out) when is_binary(out) do
    out |> String.trim() |> String.split("\n") |> Enum.take(3) |> Enum.join(" / ")
  end

  defp summarize(out), do: inspect(out)

  # Provisioning errors carry their own operator-facing message where they have
  # one (§10.2's refusal, mode A's missing token); everything else is a
  # filesystem tuple and inspects fine.
  defp describe({_tag, _path, message}) when is_binary(message), do: message
  defp describe({_tag, message}) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason)
end
