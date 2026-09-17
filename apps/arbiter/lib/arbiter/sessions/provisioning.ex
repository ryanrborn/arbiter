defmodule Arbiter.Sessions.Provisioning do
  @moduledoc """
  Builds the RFC §9.1 scaffold a session launches into (bd-aprlbb, phase 3).

  `Arbiter.Sessions.launch/1` writes the row, calls `provision/2`, then starts
  the scope. Everything a session needs to reach a working prompt without a
  human clicking through a wizard is created here, and nothing the session
  needs is left to the agent to discover:

    * the §9.1 directory tree (`Arbiter.Sessions.Layout`);
    * an **interactive** `CLAUDE_CONFIG_DIR` — `.claude.json` answering the
      three §9.2 onboarding gates, a hardened `settings.json`, and the auth
      mode's credential posture
      (`Arbiter.Agents.Claude.ConfigDir.Interactive`);
    * `.mcp.json` carrying a per-session, revocable coordinator token
      (§9.3), written mode `0600` **into the session's cwd**, which is the
      only place Claude Code loads it from;
    * a generated `CLAUDE.md` (`Arbiter.Sessions.Instructions`);
    * `memory/shared/<type>/` — the §9.4 read-only mounts, type-scoped
      (`Arbiter.Sessions.Memory`) — `user`/`feedback`/`reference` for every
      session, `project` filtered to the session's bound workspace — plus
      `memory/candidates`, the session's own write space (still just a mount
      point; promotion is a later phase);
    * `launch.sh`, the session's single argv token, and `auth.env` (mode
      `0600`, mode A only) — see "Secrets";
    * `watchdog.sh` — the §4.6 item 3 in-scope dead-man's switch. `launch.sh`
      backgrounds it before `exec`ing the agent, so it shares the scope's
      cgroup without owning the pane; it is the only reaping mechanism that
      still works if arbiter never comes back at all (phase 10, bd-3qkbch).

  ## Secrets

  §10.3 is a hard rule: never a credential on a command line, because
  `/proc/<pid>/cmdline` is world-readable on this host and the session's
  command line is a `tmux -e` list. So mode A's `CLAUDE_CODE_OAUTH_TOKEN` is
  **not** returned as env for the launcher; it is written to `auth.env` with
  mode `0600` and sourced by `launch.sh` at exec time. The only credential-ish
  thing in argv is the *path* of a file the operator's user already owns.

  Mode B's credential never moves through Arbiter at all — `ConfigDir`'s
  copy-never-symlink seeding puts it straight into the session config dir.

  Neither token nor credential is ever written to the session row, an event, or
  a log line.

  ## Idempotence

  `provision/2` is safe to re-run on an existing session dir. It re-renders the
  generated files (instructions, settings, launch wrapper) and merges into
  `.claude.json` rather than overwriting it, so a re-provision of a live
  session does not stomp Claude Code's own state — including the `bridgeOauth*`
  keys Remote Control writes there.

  Minting is **not** idempotent: each call mints a fresh token and rewrites
  `.mcp.json`. Tokens are the cheap part, and a scaffold that quietly reused a
  revoked token would be worse than one that mints again.
  """

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Claude.ConfigDir.Interactive
  alias Arbiter.Config.Paths
  alias Arbiter.MCP
  alias Arbiter.MCP.AgentConfig.Claude, as: ClaudeMCP
  alias Arbiter.Sessions.Instructions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session

  require Logger

  @secret_file_mode 0o600
  @script_mode 0o700

  @typedoc "What `provision/2` created, for the launcher and for tests."
  @type provisioned :: %{
          root: String.t(),
          cwd: String.t(),
          config_dir: String.t(),
          launch_script: String.t(),
          mcp_config: String.t() | nil,
          auth_mode: :seeded_credentials | :oauth_token
        }

  @doc """
  Provision `session`'s scaffold. Returns `{:ok, provisioned}` or
  `{:error, reason}`.

  A failure here **must** abort the launch: a session launched against an
  unseeded config dir does not fail, it hangs on the onboarding wizard with
  nobody at the keyboard (§9.2).

  ## Options

    * `:oauth_token` — mode A's token. Defaults to the one
      `ConfigDir.oauth_token/1` resolves for the session's workspace. Ignored
      in mode B.
    * `:primary_checkout` — override for §10.2's live-checkout guard.
    * `:mcp` — `false` to skip minting and `.mcp.json` entirely (a session with
      no Arbiter access at all). Defaults to `Arbiter.MCP.enabled?/0`.
    * `:extra_env` — extra **non-secret** pairs for the launch wrapper.
    * `:refine` — presence renders the refine-session instructions variant
      (`Arbiter.Sessions.Instructions.render/2`'s `:refine` option, bd-980x89)
      into the session's **cwd** as both `CLAUDE.md` and `AGENTS.md`, instead
      of the default coordinator `CLAUDE.md` at the session root.
  """
  @spec provision(Session.t(), keyword()) :: {:ok, provisioned()} | {:error, term()}
  def provision(%Session{} = session, opts \\ []) do
    id = session.id
    paths = Layout.paths(id)
    cwd = session.cwd || paths.workspace
    config_dir = session.config_dir || paths.config

    with :ok <- check_outside_primary_checkout(paths.root, opts),
         :ok <- check_outside_primary_checkout(cwd, opts),
         :ok <- make_directories(id, config_dir, cwd),
         :ok <- write_instructions(session, paths, cwd, opts),
         :ok <- mount_memory(session, opts),
         :ok <- seed_config_dir(session, config_dir, cwd, opts),
         :ok <- write_auth_env(session, paths, opts),
         {:ok, mcp_config} <- write_mcp_config(session, cwd, paths, opts),
         :ok <- write_watchdog_script(session, paths, opts),
         :ok <- write_launch_script(session, paths, config_dir, opts) do
      {:ok,
       %{
         root: paths.root,
         cwd: cwd,
         config_dir: config_dir,
         launch_script: paths.launch_script,
         mcp_config: mcp_config,
         auth_mode: session.auth_mode
       }}
    end
  end

  @doc """
  Mint this session's MCP scope token (§9.3).

  Coordinator tier, bound to the session's `workspace_id` (`nil` = the
  cross-workspace default, decision 6), and `can_dispatch` taken from the row —
  which defaults to **off** (§10.1).

  The token is returned, never stored: the only durable copy is the mode-`0600`
  `.mcp.json` inside the session's own directory. Its revocation handle is the
  row, not a stored copy.
  """
  @spec mint_token(Session.t(), keyword()) :: String.t()
  def mint_token(%Session{} = session, opts \\ []) do
    MCP.Scope.mint_session(
      session.id,
      Keyword.merge(
        [workspace_id: session.workspace_id, can_dispatch: session.can_dispatch],
        opts
      )
    )
  end

  @doc """
  Remove a session's scaffold from disk.

  Not called by the lifecycle — an ended session's directory holds its
  transcript and its candidate memories, which outlive it (§9.4, §11). This
  exists for an operator-driven cleanup and for tests.
  """
  @spec destroy(Session.t() | String.t()) :: :ok
  def destroy(%Session{id: id}), do: destroy(id)

  def destroy(id) when is_binary(id) do
    _ = File.rm_rf(Layout.session_dir(id))
    :ok
  end

  # ---- internals ----------------------------------------------------------

  # §10.2 layer 1, asserted rather than assumed. A misconfigured
  # ARBITER_SESSIONS_ROOT pointing into the live source tree fails here, loudly,
  # instead of handing an agent a cwd Phoenix hot-reload is watching.
  defp check_outside_primary_checkout(path, opts) do
    checkout = Keyword.get(opts, :primary_checkout, Paths.primary_checkout())

    if Layout.outside_primary_checkout?(path, checkout) do
      :ok
    else
      {:error,
       {:inside_primary_checkout, path,
        "refusing to provision a session under the primary checkout #{checkout} — " <>
          "§10.2 layer 1 is that a session is scaffolded, never pointed at a checkout. " <>
          "Set ARBITER_SESSIONS_ROOT to a directory outside it."}}
    end
  end

  defp make_directories(id, config_dir, cwd) do
    (Layout.directories(id) ++ [config_dir, cwd])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.mkdir_p(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir_failed, dir, reason}}}
      end
    end)
  end

  # Non-refine sessions keep the §9.1 shape unchanged: one generated
  # `CLAUDE.md` at the session root (an ancestor of the cwd, so Claude Code's
  # directory walk still finds it). A refine session (`opts[:refine]` present,
  # bd-980x89) instead renders into the **cwd itself**, as both `CLAUDE.md`
  # and `AGENTS.md` — the latter for non-Claude providers, since a refine
  # session's doctrine is not optional reading gated behind one CLI's
  # conventions.
  defp write_instructions(session, paths, cwd, opts) do
    content =
      Instructions.render(session,
        primary_checkout: Keyword.get(opts, :primary_checkout, Paths.primary_checkout()),
        mcp_server_name: MCP.server_name(),
        refine: Keyword.get(opts, :refine)
      )

    case Keyword.get(opts, :refine) do
      nil ->
        write_file(paths.instructions, content)

      _refine ->
        with :ok <- write_file(Path.join(cwd, "CLAUDE.md"), content) do
          write_file(Path.join(cwd, "AGENTS.md"), content)
        end
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  # §9.4 — mounts read-only into memory/shared/<type>/, filtered by
  # `metadata.type` and (for `project`) the session's bound workspace.
  # Best-effort: `Memory.mount/2` never fails provisioning over an absent or
  # unreadable memory root, since memory is additive context.
  defp mount_memory(session, opts) do
    Memory.mount(session, Keyword.take(opts, [:memory_root]))
  end

  defp seed_config_dir(session, config_dir, cwd, opts) do
    Interactive.ensure(config_dir,
      cwd: cwd,
      auth_mode: session.auth_mode,
      source_dir: credentials_source(opts),
      primary_checkout: Keyword.get(opts, :primary_checkout, Paths.primary_checkout()),
      # Pre-approve exactly the server `write_mcp_config/3` is about to declare,
      # and nothing when it is about to declare none (bd-5xlkkj). Without this a
      # first launch stops on "New MCP server found in this project: arbiter"
      # with nobody at the keyboard to answer it.
      mcp_servers: mcp_servers(opts)
    )
  end

  defp mcp_servers(opts) do
    if Keyword.get(opts, :mcp, MCP.enabled?()), do: [MCP.server_name()], else: []
  end

  @doc """
  The operator config dir mode B copies `.credentials.json` from.

  Defaults to `ConfigDir.source_dir/0` — the operator's real `~/.claude`, which
  is the whole point of mode B (§8.2: every mode-B session authenticates as the
  operator). `config :arbiter, :sessions_credentials_source, "/path"` overrides
  it, which is how the **test suite** points it at a directory that does not
  exist: a suite run must never copy the operator's live grant into a tmp
  scaffold, and "don't provision in tests" is not available now that
  provisioning is part of `launch/1`.
  """
  @spec credentials_source(keyword()) :: String.t() | nil
  def credentials_source(opts \\ []) do
    cond do
      Keyword.has_key?(opts, :credentials_source) -> Keyword.get(opts, :credentials_source)
      source = Application.get_env(:arbiter, :sessions_credentials_source) -> source
      true -> ConfigDir.source_dir()
    end
  end

  # Mode A only. The token reaches the agent through a mode-0600 file the
  # wrapper sources — never through argv (§10.3).
  defp write_auth_env(%Session{auth_mode: :oauth_token} = session, paths, opts) do
    case oauth_token(session, opts) do
      nil ->
        {:error,
         {:missing_oauth_token,
          "auth mode A (:oauth_token) needs a CLAUDE_CODE_OAUTH_TOKEN for " <>
            "workspace #{inspect(session.workspace_id)}, and none is configured. " <>
            "Configure one on the workspace, or launch in mode B (:seeded_credentials)."}}

      token ->
        write_secret(paths.auth_env, "CLAUDE_CODE_OAUTH_TOKEN=#{token}\n")
    end
  end

  defp write_auth_env(%Session{}, paths, _opts) do
    # Mode B carries no env secret. Remove a stale file from a previous mode-A
    # provisioning of the same session rather than leaving a live token behind.
    _ = File.rm(paths.auth_env)
    :ok
  end

  defp oauth_token(session, opts) do
    case Keyword.fetch(opts, :oauth_token) do
      {:ok, token} -> token
      :error -> ConfigDir.oauth_token(session.workspace_id)
    end
  end

  # Written into the session's **cwd**, not the session root: Claude Code
  # auto-loads `.mcp.json` from the working directory only
  # (`Arbiter.MCP.AgentConfig.Claude`), and `launch.sh` cd's into that cwd
  # before exec'ing the agent. One directory out and the session starts with no
  # Arbiter MCP server at all.
  defp write_mcp_config(session, cwd, paths, opts) do
    path = Path.join(cwd, ClaudeMCP.filename())

    if Keyword.get(opts, :mcp, MCP.enabled?()) do
      # Narrowed on purpose: `opts` here is the whole `launch/1` keyword list
      # (`:runner`, `:cwd`, `:cols`, an OAuth token…), and `MCP.mint/2` forwards
      # its options straight into `Plug.Crypto.sign/4`. Only the claim-shaping
      # and TTL keys belong in a crypto call.
      token =
        mint_token(session, Keyword.take(opts, [:workspace_id, :can_dispatch, :max_age, :depth]))

      # Same discipline as `write_secret/2`: the file exists at 0600 *before*
      # the adapter writes a live bearer token into it, so it is never briefly
      # readable at the default umask. `File.write/2` truncates an existing file
      # without touching its mode, so the adapter's own write inherits 0600.
      with :ok <- touch_secret(path),
           :ok <-
             ClaudeMCP.write_mcp_config(cwd,
               mcp_url: MCP.server_url(),
               scope_token: token,
               server_name: MCP.server_name()
             ),
           :ok <- write_secret(paths.mcp_token, token),
           :ok <- write_monitor_files(session, paths, token) do
        {:ok, path}
      else
        {:error, {:write_failed, _, _} = reason} -> {:error, reason}
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    else
      _ = File.rm(path)
      _ = File.rm(paths.mcp_token)
      _ = File.rm(paths.monitor_curlrc)
      _ = File.rm(paths.monitor_script)
      _ = File.rm(paths.monitor_cursor)
      {:ok, nil}
    end
  end

  # The session's own event monitor (bd-aqafdr): a `curl -K` loop over
  # `/events` that reads its bearer token from a mode-0600 curl config
  # instead of a header flag, so the token never lands on `monitor.sh`'s own
  # argv, and never calls `arb mcp token mint` (that route is the
  # unauthenticated loopback mint a session must not escalate through,
  # bd-5b5hq7 — the session's own already-scoped, revocable token is reused
  # instead). Armed by the `SessionStart` hook
  # (`Arbiter.Agents.Claude.ConfigDir.Interactive`); the agent runs it via
  # the Monitor tool, never background Bash (an infinite loop never exits,
  # so `run_in_background` never notifies).
  defp write_monitor_files(session, paths, token) do
    with :ok <- write_secret(paths.monitor_curlrc, curlrc(token)) do
      case File.write(paths.monitor_script, monitor_script(session, paths)) do
        :ok -> chmod(paths.monitor_script, @script_mode)
        {:error, reason} -> {:error, {:write_failed, paths.monitor_script, reason}}
      end
    end
  end

  defp curlrc(token), do: ~s(header = "Authorization: Bearer #{token}"\n)

  defp monitor_script(session, paths) do
    """
    #!/bin/sh
    # Generated by Arbiter.Sessions.Provisioning for session #{session.id}.
    # Regenerated on every provision — do not edit.
    #
    # The session's own event monitor (bd-aqafdr). Reads the bearer token
    # from a mode-0600 curl config (`curl -K`) so it never appears on this
    # script's own argv, and never calls `arb mcp token mint` — the token
    # here is the session's own, already scoped and revocable (bd-5b5hq7).
    # Run this via the Monitor tool (persistent: true), never background
    # Bash: this loop only exits if the session's token is revoked/expired
    # server-side, so `run_in_background` would never see it finish either.
    #
    # `--max-time 240` bounds each individual connection (proxies and load
    # balancers can silently drop long-lived idle connections); the outer
    # `while true` reconnects immediately, re-reading the cursor file each
    # time so a reconnect resumes from the last event actually seen instead
    # of replaying from the start or re-using a stale `since=`.
    set -e

    CURLRC=#{shell_quote(paths.monitor_curlrc)}
    CURSOR_FILE=#{shell_quote(paths.monitor_cursor)}

    while true; do
      since=""
      if [ -s "$CURSOR_FILE" ]; then
        since="&since=$(cat "$CURSOR_FILE")"
      fi

      curl -K "$CURLRC" -sN --max-time 240 \\
        "#{Arbiter.MCP.events_url()}?subscribe=inbox,review_gate,worker_done,worker_failed$since" |
      while IFS= read -r line; do
        printf '%s\\n' "$line"
        cursor=$(printf '%s' "$line" | sed -n 's/.*"cursor":\\([0-9]*\\).*/\\1/p')
        if [ -n "$cursor" ]; then
          printf '%s' "$cursor" > "$CURSOR_FILE"
        fi
      done

      sleep 1
    done
    """
  end

  # The one argv token of a launched session. A wrapper, not a bare `claude`
  # invocation, precisely so a credential can be a file read at exec time
  # rather than a flag (§10.3).
  defp write_launch_script(session, paths, config_dir, opts) do
    env =
      [
        {"CLAUDE_CONFIG_DIR", config_dir},
        {"ARB_SESSION_ID", session.id},
        {"ARB_SESSION_ROOT", paths.root}
      ] ++ Keyword.get(opts, :extra_env, [])

    exports = Enum.map_join(env, "\n", fn {k, v} -> "export #{k}=#{shell_quote(v)}" end)

    script = """
    #!/bin/sh
    # Generated by Arbiter.Sessions.Provisioning for session #{session.id}.
    # Regenerated on every provision — do not edit.
    #
    # This wrapper exists so credentials never appear in argv (RFC §10.3):
    # /proc/<pid>/cmdline is world-readable on this host, and the session's
    # command line is a `tmux -e` list. Mode A's token is read from a
    # mode-0600 file here instead.
    set -e

    #{exports}

    # Mode A only; absent in mode B, where the credential is a copy inside
    # CLAUDE_CONFIG_DIR that the CLI reads for itself.
    if [ -r #{shell_quote(paths.auth_env)} ]; then
      set -a
      . #{shell_quote(paths.auth_env)}
      set +a
    fi

    # In-scope dead-man's switch (§4.6 item 3), backgrounded so it does not
    # block the `exec` below. Cgroup membership is inherited by fork() and
    # untouched by the parent shell being replaced, so it survives — the same
    # property that keeps the tmux server itself alive in its own scope
    # (§4.1). If watchdog.sh is missing (an old provision, or provisioning
    # skipped) this is a silent no-op: `sh` just reports "not found" to
    # nowhere, since stderr is redirected.
    #{shell_quote(paths.watchdog_script)} >/dev/null 2>&1 &

    cd #{shell_quote(session.cwd || paths.workspace)}
    exec #{agent_command(session, opts)}
    """

    with :ok <- File.write(paths.launch_script, script),
         :ok <- chmod(paths.launch_script, @script_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, paths.launch_script, reason}}
    end
  end

  # The §4.6 item 3 in-scope dead-man's switch. A background sibling of the
  # agent, not a wrapper around it: it never touches the agent's stdio, and it
  # only ever acts on the pane through `tmux kill-session` by exact socket +
  # session name — the same discipline `Arbiter.Sessions.kill/2` and
  # `Arbiter.Sessions.OrphanReaper` use, never a pattern match.
  defp write_watchdog_script(session, paths, opts) do
    case Naming.heartbeat_path() do
      {:ok, heartbeat} ->
        script = watchdog_script(session, heartbeat, opts)

        with :ok <- File.write(paths.watchdog_script, script),
             :ok <- chmod(paths.watchdog_script, @script_mode) do
          :ok
        else
          {:error, reason} -> {:error, {:write_failed, paths.watchdog_script, reason}}
        end

      {:error, :no_runtime_dir} = error ->
        error
    end
  end

  defp watchdog_script(session, heartbeat, opts) do
    """
    #!/bin/sh
    # Generated by Arbiter.Sessions.Provisioning for session #{session.id}.
    # Regenerated on every provision — do not edit.
    #
    # The in-scope dead-man's switch (RFC §4.6 item 3): the only reaping
    # mechanism that still works if arbiter never comes back at all — §4.2
    # measured a scope staying `active`, tmux serving indefinitely, after
    # arbiter was stopped entirely. Exits (after killing this session's tmux
    # pane) once BOTH are true: arbiter's heartbeat file has not been touched
    # within the grace window, AND no tmux client is attached. Neither alone
    # is enough — a plain arbiter restart, or a client that briefly detached,
    # must not reap a session that is otherwise fine.
    SOCKET=#{shell_quote(session.tmux_socket)}
    TMUX_SESSION=#{shell_quote(Naming.tmux_session())}
    HEARTBEAT=#{shell_quote(heartbeat)}
    GRACE=#{deadman_grace_seconds(opts)}
    POLL=#{deadman_poll_seconds(opts)}

    while :; do
      sleep "$POLL"

      tmux -S "$SOCKET" has-session -t "$TMUX_SESSION" >/dev/null 2>&1 || exit 0

      now=$(date +%s)
      if [ -r "$HEARTBEAT" ]; then
        hb=$(stat -c %Y "$HEARTBEAT" 2>/dev/null)
        [ -n "$hb" ] || hb=$(stat -f %m "$HEARTBEAT" 2>/dev/null)
        [ -n "$hb" ] || hb=$now
      else
        hb=0
      fi
      age=$((now - hb))
      [ "$age" -ge "$GRACE" ] || continue

      clients=$(tmux -S "$SOCKET" list-clients -t "$TMUX_SESSION" 2>/dev/null | wc -l)
      [ "$clients" -eq 0 ] || continue

      tmux -S "$SOCKET" kill-session -t "$TMUX_SESSION" >/dev/null 2>&1
      exit 0
    done
    """
  end

  @doc """
  The agent invocation the launch wrapper `exec`s.

  Overridable with `config :arbiter, :sessions_agent_command, "…"` (or the
  `:agent_command` option) — which is how the live-systemd integration check
  pins a deterministic payload, and how an install with `claude` somewhere
  unusual points at it. Either override wins outright and skips `--name`
  entirely — a pinned/overridden payload is exactly what it says, not a
  template to append flags to.

  Absent an override, an operator-supplied `session.name` (bd-o2vtsz) becomes
  `claude --name <name>`, single-quoted with embedded quotes escaped — the
  name is operator text landing in a generated `sh` script that is `exec`'d,
  so unescaped it would be command injection running as the operator. No name
  → a bare `claude`, unchanged from before this option existed.

  `session.remote_control` (§8) appends `--remote-control <id>`, single-quoted
  the same way — the session's own id, per design consequence 3 (§8.3), not
  the operator name, so a claude.ai session is traceable back to the row that
  launched it regardless of what (or whether) the operator named it. The
  `Session` resource's validation already refuses `remote_control: true`
  outside mode B (§8.3), so this never needs to check `auth_mode` itself.
  """
  @spec agent_command(Session.t(), keyword()) :: String.t()
  def agent_command(%Session{} = session, opts \\ []) do
    Keyword.get(opts, :agent_command) ||
      Application.get_env(:arbiter, :sessions_agent_command) ||
      default_agent_command(session)
  end

  defp default_agent_command(%Session{} = session) do
    ["claude"]
    |> append_name(session)
    |> append_remote_control(session)
    |> Enum.join(" ")
  end

  defp append_name(parts, %Session{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> parts
      trimmed -> parts ++ ["--name", shell_quote(trimmed)]
    end
  end

  defp append_name(parts, %Session{}), do: parts

  defp append_remote_control(parts, %Session{remote_control: true, id: id}) do
    parts ++ ["--remote-control", shell_quote(id)]
  end

  defp append_remote_control(parts, %Session{}), do: parts

  @doc """
  The dead-man's switch grace window, in seconds (§4.6 item 3, suggested 1h).

  `config :arbiter, :sessions_deadman, grace_seconds: N` overrides it.
  """
  @spec deadman_grace_seconds(keyword()) :: pos_integer()
  def deadman_grace_seconds(opts \\ []) do
    Keyword.get(opts, :deadman_grace_seconds) || deadman_cfg(:grace_seconds, 3600)
  end

  @doc """
  The dead-man's switch poll interval, in seconds.

  `config :arbiter, :sessions_deadman, poll_seconds: N` overrides it.
  """
  @spec deadman_poll_seconds(keyword()) :: pos_integer()
  def deadman_poll_seconds(opts \\ []) do
    Keyword.get(opts, :deadman_poll_seconds) || deadman_cfg(:poll_seconds, 60)
  end

  defp deadman_cfg(key, default) do
    get_in(Application.get_env(:arbiter, :sessions_deadman, []), [key]) || default
  end

  defp write_secret(path, contents) do
    with :ok <- touch_secret(path),
         :ok <- File.write(path, contents) do
      :ok
    else
      {:error, {:write_failed, _, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  # Create the file empty at 0600 *before* anything writes a secret into it, so
  # the secret is never briefly readable at the default umask.
  defp touch_secret(path) do
    case File.write(path, "") do
      :ok -> chmod(path, @secret_file_mode)
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Arbiter.Sessions.Provisioning: could not chmod #{inspect(path)} to " <>
            "#{inspect(mode, base: :octal)} (#{inspect(reason)})"
        )

        :ok
    end
  end

  # Single-quote for /bin/sh, escaping embedded single quotes the only way sh
  # allows. Paths here are Arbiter-derived, but a session id or a configured
  # root is still data, and data does not belong unquoted in a generated script.
  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end
end
