defmodule Arbiter.Sessions.Stream do
  @moduledoc """
  The **reader**: one process per live session, fanning its terminal output out
  to attached clients (bd-3ymdvi, phase 4 of
  `docs/browser-hosted-coordinator-sessions.md` §5.3).

  It owns the four things §5.3 asks for — a monotonic `seq`, a bounded replay
  ring, resume, and backpressure — and nothing else. It is transport-agnostic:
  it talks to plain pids with plain messages, so `ArbiterWeb.SessionChannel` is
  a translation layer rather than the protocol itself, and the same reader can
  be driven from a test, a CLI, or a second transport later.

  ## One reader per session, not per client

  The RFC says "one reader per attached browser". tmux makes that literally
  impossible: `pipe-pane` is a property **of the pane**, singular — issuing it
  twice replaces the first pipe rather than adding a second. It is also the
  wrong shape for §5.3, which wants one `seq` space and one ring per *session*
  so that two clients resuming from different points are talking about the
  same numbers. So: one reader per session, shared by every attached client,
  started on first attach.

  Unlike earlier revisions of this module, the reader is **not** stopped when
  the last client detaches — detaching only drops that client's subscriber
  entry (bd-5pelo2 finding 1). §11's raw transcript (`Arbiter.Sessions.Transcript`)
  is written from this same reader's poll loop, so a reader that stopped at
  the last detach meant nothing was captured while a session ran unattended,
  which inverts the whole point of the artefact. The reader now runs for the
  rest of the session's life — through every detach, with zero subscribers if
  need be — and is only stopped by a genuine session end (`:alive` finding
  the pane gone, or an `arbiter` restart, which drops the reader but never the
  session: the pipe keeps writing to its file regardless, and a fresh reader
  adopts it on the next attach).

  This closes the gap for any session a browser attaches to at least once.
  It does **not** yet cover a session nobody ever attaches to at all — the
  pipe is only started by the first `attach/2`, same as before. That
  remaining gap is a deliberate, documented deferral (see
  `docs/browser-hosted-coordinator-sessions.md` §11); closing it needs the
  reader started from session launch/adoption rather than from the channel,
  which touches enough of the launch and adoption call paths to be its own
  change.

  It also does not yet cover the bytes a pane writes to its pipe file *while*
  no reader is alive — the `arbiter` restart window above. `open_stream/1`
  seeks to the pipe file's current size before adopting it (for the resume
  transport seam, §4.5 — the client-facing snapshot covers that gap
  visually), which means the durable transcript (`Arbiter.Sessions.Transcript`)
  silently skips whatever the pane wrote during the dead stretch. Same class
  of documented gap as the never-attached case above, just restart-triggered
  (bd-5pelo2, round 2, finding 3; see `docs/browser-hosted-coordinator-sessions.md` §11).

  ## `seq` is a byte offset, not a counter

      seq == byte offset into the session's pipe file

  This is the single most useful invariant here. It makes resume arithmetic
  trivial (`missed = pread(file, last_seq, head - last_seq)`), it survives an
  `arbiter` restart for free (the `cat` tmux spawned is in the *session's*
  scope and keeps appending while we are dead, so a new reader picks the
  numbering straight back up from the file size), and it means the ring is a
  cache rather than the source of truth. Frames are `Arbiter.Sessions.Frame`
  binaries carrying `seq` in the payload, because a Phoenix binary push has
  nowhere else to put it.

  ## The §4.5 overlap seam

  On attach the reader:

  1. creates the pipe file if needed and records its size — this becomes the
     starting `seq`;
  2. asks the terminal to start piping **and** to capture scrollback, in that
     order and in one operation.

  Any byte the pipe catches between (1) and (2) is therefore also in the
  snapshot: an **overlap**, which §4.5 says is cheap, rather than a **gap**,
  which it says is unrecoverable. Bytes produced while nobody was attached are
  in the file but are deliberately not replayed as frames — the snapshot
  already shows their effect on the screen.

  ## Backpressure (§5.3 item 2)

  A browser on a slow link must not grow the BEAM's heap. Two mechanisms:

    * **Coalescing.** The reader polls the pipe file and ships *one* frame per
      tick containing everything that arrived, so a burst becomes a big frame
      rather than a long queue.
    * **Drop to snapshot.** Each subscriber acknowledges the bytes it has
      pushed onto the wire (`ack/3`). Once a subscriber's unacknowledged bytes
      reach the high-water mark it is moved to `:dropping`: the reader stops
      sending it anything and keeps no backlog for it. When its acknowledgements
      catch up it gets **one** fresh `capture-pane` snapshot and resumes live.
      A terminal's value is its current contents; the present, instantly, beats
      a backlog the user would scroll past.

  `stdin` needs none of this — human typing is orders of magnitude slower than
  any PTY.

  ## Resize policy (§12 open question)

  **Last writer wins.** The most recent `resize` from any attached client sets
  the pane size, and every client — including the one that asked — is told the
  new geometry with a `meta` event so it can re-fit. This matches tmux's own
  `window-size latest` default and avoids the classic multi-attach squeeze
  where everyone is clamped to the smallest window. Simple, documented, and
  cheap to change once the frontend has opinions.

  ## Configuration

      config :arbiter, Arbiter.Sessions.Stream,
        ring_bytes: 2_097_152,        # §5.3's suggested 2 MB replay ring
        max_replay_bytes: 2_097_152,  # largest gap resumed instead of repainted
        high_water_bytes: 262_144,    # §5.3's suggested 256 KB pending cap
        low_water_bytes: 65_536,      # acks below this end :dropping mode
        read_chunk_bytes: 65_536,     # max payload per frame
        poll_interval_ms: 25,
        alive_interval_ms: 1_000,
        usage_poll_interval_ms: 2_000, # live cost HUD cadence (§7.5, phase 7)
        snapshot_lines: 2_000

  Every key is also accepted as an option to `attach/2`, which is how the
  suite drives it. Configuration is fixed by the **first** attach for the
  reader's lifetime.

  ## Live cost HUD (§7.5, phase 7)

  Same reader, one more timer: every `usage_poll_interval_ms` (~2s), while at
  least one client is attached, it re-reads the session's on-disk JSONL with
  `Arbiter.Usage.ClaudeSessionFile.read_totals/2` — the same reconciliation
  arithmetic `Arbiter.Sessions.UsageIngest` already uses, reused rather than
  reimplemented — and publishes the file's *cumulative* totals as a `usage`
  event on `Arbiter.Sessions.usage_topic/1`. `ArbiterWeb.SessionChannel`
  subscribes to that topic independently of this reader's own `subs` (it is
  PubSub, not a direct send), so multiple attached tabs share one tailer —
  and, because the payload is always the file's running total rather than a
  delta since some reader-private baseline, a tab that attaches midway
  through the session's life (or reattaches after the reader restarted) shows
  the correct number on the very next tick instead of resuming from zero.

  `estimated` mirrors `totals.cost_source == :estimated` — true only when the
  figure came from `Arbiter.Usage.ClaudePricing`'s token-based estimate. A
  file with no cost at all (`cost_source: nil`, e.g. an unpriced model) is
  reported with `cost_usd: nil` and `estimated: false` — a missing number is
  not the same claim as an estimated one.

  Reading and JSON-decoding a whole session transcript is not free, so two
  guards keep this timer from competing with the 25ms PTY poll and the
  synchronous `attach`/`send_input`/`snapshot` calls this same GenServer must
  keep answering: a tick is skipped entirely when the file's `{size, mtime}`
  is unchanged since the last read, and the read that does happen runs in a
  short-lived `Task` (`Arbiter.TaskSupervisor`) rather than inline, with the
  reader tracking one in-flight ref so a slow read is never started twice
  concurrently.

  `session.provider_session_id` is nullable at launch (the CLI picks it, not
  Arbiter — see `Arbiter.Sessions.Session`'s moduledoc). Until it is known,
  the reader discovers it itself: the newest `*.jsonl` under
  `session.config_dir/projects/*/`, by mtime, is assumed to be the file the
  CLI is currently appending to. The discovered id is persisted back onto the
  row with `Arbiter.Sessions.record_provider_session/2` (best-effort — a
  failure to persist is not fatal to the tick, since the id is still used to
  read *this* tick's totals) so `Arbiter.Sessions.usage_events/1`, whose only
  other writer this column has, sees it too.

  The same discovery is also how the §7.5 rollover wrinkle stays closed for
  the *whole* session, not just its start: `--resume`/compaction rolls the
  CLI onto a new `<sid>.jsonl` without deleting the old one, so a stale
  `provider_session_id` would keep resolving forever if the reader only
  discovered on an outright `locate/2` miss. Instead every tick with a known
  id also checks for a newer `*.jsonl` in the same config dir and switches
  (and persists) onto it when one exists — so a rollover mid-session, not
  just a missing file, re-discovers rather than going dark.

  This reads `session.config_dir` as it was at the reader's own start (or
  last resume) rather than re-fetching the row every tick — cheap, and
  consistent with every other use of `state.session` in this module.
  """

  use GenServer

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Usage.ClaudeSessionFile

  require Logger

  @registry Arbiter.Sessions.Stream.Registry
  @supervisor Arbiter.Sessions.Stream.Supervisor

  @defaults [
    ring_bytes: 2_097_152,
    max_replay_bytes: 2_097_152,
    high_water_bytes: 262_144,
    low_water_bytes: 65_536,
    read_chunk_bytes: 65_536,
    poll_interval_ms: 25,
    alive_interval_ms: 1_000,
    usage_poll_interval_ms: 2_000
  ]

  # Rounds `attach/2` will re-resolve the reader over before giving up. Three
  # is generous: the window it covers is the registry's handling of one
  # `:DOWN`, not any kind of real work.
  @attach_attempts 3
  @attach_retry_ms 5

  # bd-bsdeb2 finding 3: `Terminal.Tmux.alive?/2` is one unretried exit-code
  # check — a transient tmux/socket hiccup reads identically to a real exit,
  # and ending a session is irreversible (it revokes the MCP token and takes
  # the row out of adoption's re-adopt set). Require this many *consecutive*
  # dead polls before believing it.
  @dead_polls_required 2

  @type attached :: %{
          seq: non_neg_integer(),
          mode: :resumed | :snapshot,
          snapshot: binary() | nil,
          replay: [binary()],
          meta: meta()
        }

  @type meta :: %{
          cols: pos_integer(),
          rows: pos_integer(),
          attached_clients: non_neg_integer(),
          title: String.t()
        }

  # -- client API -------------------------------------------------------------

  @doc """
  Attach a subscriber to `session`, starting the reader if nobody else has.

  ## Options

    * `:subscriber` — the pid to stream to. Defaults to the caller.
    * `:last_seq` — resume point. `nil` (default) asks for a full snapshot.
    * `:cols` / `:rows` — the client's geometry; applied under the last-writer-wins
      rule when both are **positive integers**. A client that cannot measure
      itself yet leaves the pane's size alone, whether it says so with `nil` or
      with the `0` a browser reports for an unlaid-out terminal.
    * `:terminal` — the `Arbiter.Sessions.Terminal` to use. Test seam.
    * `:pipe_dir` — where the pipe file lives. Test seam.
    * plus any configuration key from the moduledoc.

  Returns `{:ok, t:attached/0}`. `mode` is `:resumed` when `last_seq` was in
  range — `replay` then holds exactly the missed frames, in order, and
  `snapshot` is `nil`. Otherwise `mode` is `:snapshot`, `snapshot` holds
  ANSI-preserving scrollback, and the client resets its sequence to `seq`.

  Subscribers then receive, until they detach or die:

      {:session_stdout,   session_id, frame}   # Frame.encode(seq, bytes)
      {:session_snapshot, session_id, %{seq: seq, data: bytes}}
      {:session_meta,     session_id, meta}
      {:session_exit,     session_id, %{code: code, reason: reason}}
  """
  @spec attach(Session.t(), keyword()) :: {:ok, attached()} | {:error, term()}
  def attach(%Session{} = session, opts \\ []), do: attach(session, opts, @attach_attempts)

  # A reader replies to `detach` and *then* terminates, and the registry drops
  # its entry only when it handles the resulting `:DOWN` — which is not ordered
  # against anything the caller can see. So `ensure_started/2` can hand back a
  # pid that is already on its way out, and the call to it exits `:noproc`.
  # That window is exactly a browser reload, or a second tab opening as the
  # first closes, so it is retried rather than surfaced as a crash.
  defp attach(session, opts, attempts) do
    subscriber = Keyword.get(opts, :subscriber, self())

    with {:ok, pid} <- ensure_started(session, opts) do
      GenServer.call(
        pid,
        {:attach, subscriber, Keyword.get(opts, :last_seq), Keyword.get(opts, :cols),
         Keyword.get(opts, :rows)}
      )
    end
  catch
    :exit, reason when attempts > 1 ->
      Logger.debug("Sessions.Stream #{session.id}: reader went away mid-attach, retrying")
      _ = reason
      Process.sleep(@attach_retry_ms)
      attach(session, opts, attempts - 1)

    :exit, reason ->
      {:error, {:reader_unavailable, reason}}
  end

  @doc """
  Detach a subscriber. The session keeps running (AC 2).

  The reader itself keeps running too, even once the last subscriber leaves —
  it still owns the §11 raw-transcript capture, which must not stop just
  because nobody is watching (bd-5pelo2 finding 1). A later reattach picks
  the same `seq` space back up directly, with nothing to repaint.
  """
  @spec detach(String.t(), pid()) :: :ok
  def detach(session_id, subscriber \\ self()) do
    call(session_id, {:detach, subscriber}, :ok)
  end

  @doc "Type raw bytes into the pane. Only attached subscribers may."
  @spec input(String.t(), binary(), pid()) :: :ok | {:error, term()}
  def input(session_id, bytes, subscriber \\ self()) when is_binary(bytes) do
    call(session_id, {:input, subscriber, bytes}, {:error, :session_gone})
  end

  @doc "Resize the pane (last writer wins) and `meta` every attached client."
  @spec resize(String.t(), pos_integer(), pos_integer(), pid()) :: :ok | {:error, term()}
  def resize(session_id, cols, rows, subscriber \\ self())
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    call(session_id, {:resize, subscriber, cols, rows}, {:error, :session_gone})
  end

  @doc """
  Acknowledge `bytes` written to the wire — the backpressure signal.

  A transport calls this after handing a frame to its socket. Unacknowledged
  bytes above the high-water mark move the subscriber to `:dropping`; falling
  back under the low-water mark repaints it with a snapshot and resumes live.
  """
  @spec ack(String.t(), non_neg_integer(), pid()) :: :ok
  def ack(session_id, bytes, subscriber \\ self()) when is_integer(bytes) and bytes >= 0 do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ack, subscriber, bytes})
    end
  end

  @doc "Current geometry, client count and title, or `{:error, :session_gone}`."
  @spec meta(String.t()) :: {:ok, meta()} | {:error, :session_gone}
  def meta(session_id), do: call(session_id, :meta, {:error, :session_gone})

  @doc "Reader internals, for tests and the HUD: seq, ring bounds, subscribers."
  @spec stats(String.t()) :: map() | nil
  def stats(session_id), do: call(session_id, :stats, nil)

  @doc "The reader pid for a session, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Stop a reader. Tolerates one that is already gone."
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  @doc false
  def start_link({session, opts}) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via(session.id))
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  defp ensure_started(session, opts) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {session, opts}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call(session_id, message, fallback) do
    case whereis(session_id) do
      nil -> fallback
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> fallback
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init({session, opts}) do
    config = config(opts)

    state = %{
      session: session,
      id: session.id,
      terminal: Sessions.terminal(opts),
      opts: opts,
      config: config,
      path: pipe_path(session, opts),
      redact_values: redact_values(session, opts),
      fd: nil,
      seq: 0,
      ring: :queue.new(),
      ring_bytes: 0,
      ring_base: 0,
      subs: %{},
      cols: 80,
      rows: 24,
      title: "",
      pending_snapshot: nil,
      open_error: nil,
      transcript_handle: nil,
      transcript_tail: <<>>,
      last_turn_touch_ms: nil,
      usage_task_ref: nil,
      usage_file_stat: nil,
      dead_polls: 0
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state) do
    case open_stream(state) do
      {:ok, state} ->
        schedule(:poll, state.config.poll_interval_ms)
        schedule(:alive, state.config.alive_interval_ms)
        schedule(:usage_poll, state.config.usage_poll_interval_ms)
        {:noreply, refresh_geometry(state)}

      {:error, reason} ->
        # Stay alive just long enough to hand the error to whoever is about to
        # call `attach/2`; stopping here would surface as a supervisor report
        # instead of a return value.
        {:noreply, %{state | open_error: reason}}
    end
  end

  @impl GenServer
  def handle_call({:attach, _pid, _last_seq, _cols, _rows}, _from, %{open_error: error} = state)
      when not is_nil(error) do
    {:stop, :normal, {:error, error}, state}
  end

  def handle_call({:attach, pid, last_seq, cols, rows}, _from, state) do
    state =
      if Map.has_key?(state.subs, pid) do
        state
      else
        ref = Process.monitor(pid)

        state =
          put_in(state.subs[pid], %{
            ref: ref,
            inflight: 0,
            mode: :live,
            needs_snapshot: false
          })

        # A joining client (first attach, or reattach after the reader
        # restarted) has never seen a `usage` event. The `{size, mtime}` skip
        # in `maybe_read_usage/3` is reader-global, so without this the next
        # tick would still skip an unchanged file and leave this client's HUD
        # blank indefinitely. Clearing it forces one re-read on the next tick,
        # which `publish_usage/2` broadcasts to every attached client.
        %{state | usage_file_stat: nil}
      end

    # `0` is truthy in Elixir, and a browser really does report it: xterm.js's
    # fit addon measures 0×0 for a terminal whose container has not been laid
    # out yet — a background tab, or a join before first paint. Handing that to
    # `Terminal.resize/4`, whose contract (and every implementation's guard) is
    # `pos_integer()`, would kill the reader *every other client shares*. Same
    # check as `resize/4`'s own guard.
    state = if geometry?(cols, rows), do: apply_resize(state, cols, rows), else: state
    {resume, state} = resume(state, last_seq)

    # Everyone *else* learns the client count changed; the joiner is told in
    # its own reply, so its mailbox holds exactly one meta for this event.
    broadcast_meta(state, except: pid)

    {:reply, {:ok, Map.put(resume, :meta, meta_payload(state))}, state}
  end

  def handle_call({:detach, pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call({:input, pid, bytes}, _from, state) do
    if Map.has_key?(state.subs, pid) do
      {:reply, state.terminal.send_input(state.session, bytes, state.opts), state}
    else
      {:reply, {:error, :not_attached}, state}
    end
  end

  def handle_call({:resize, pid, cols, rows}, _from, state) do
    if Map.has_key?(state.subs, pid) do
      state = apply_resize(state, cols, rows)
      broadcast_meta(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_attached}, state}
    end
  end

  def handle_call(:meta, _from, state), do: {:reply, {:ok, meta_payload(state)}, state}

  def handle_call(:stats, _from, state) do
    subscribers =
      Enum.map(state.subs, fn {pid, sub} ->
        %{pid: pid, inflight: sub.inflight, mode: sub.mode}
      end)

    {:reply,
     %{
       seq: state.seq,
       ring_bytes: state.ring_bytes,
       ring_base: state.ring_base,
       cols: state.cols,
       rows: state.rows,
       title: state.title,
       attached_clients: map_size(state.subs),
       subscribers: subscribers
     }, state}
  end

  @impl GenServer
  def handle_cast({:ack, pid, bytes}, state) do
    case Map.fetch(state.subs, pid) do
      :error ->
        {:noreply, state}

      {:ok, sub} ->
        sub = %{sub | inflight: max(0, sub.inflight - bytes)}
        state = put_in(state.subs[pid], sub)

        if sub.mode == :dropping and sub.inflight <= state.config.low_water_bytes do
          {:noreply, repaint(state, pid)}
        else
          {:noreply, state}
        end
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = pump(state)
    schedule(:poll, state.config.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:alive, state) do
    if state.terminal.alive?(state.session, state.opts) do
      schedule(:alive, state.config.alive_interval_ms)
      {:noreply, refresh_geometry(%{state | dead_polls: 0})}
    else
      state = %{state | dead_polls: state.dead_polls + 1}

      if state.dead_polls < @dead_polls_required do
        # Not corroborated yet — could be a transient tmux/socket hiccup.
        # Poll again rather than believing a single dead reading.
        schedule(:alive, state.config.alive_interval_ms)
        {:noreply, state}
      else
        # Drain whatever the pane wrote on its way out before announcing it.
        state = pump(state)
        # bd-bsdeb2: end the row *before* telling attached clients, so a client
        # that reacts to the broadcast by re-fetching the session (the
        # `agent_exited` hook path) already sees `:ended`. Best-effort — the
        # in-memory `session` here can be stale or, in some tests, unpersisted;
        # either way the pane is gone and clients must still be told.
        _ = Sessions.mark_ended(state.session, "exited")
        broadcast(state, {:session_exit, state.id, %{code: nil, reason: "exited"}})
        {:stop, :normal, close_stream(state)}
      end
    end
  end

  def handle_info(:usage_poll, state) do
    schedule(:usage_poll, state.config.usage_poll_interval_ms)
    {:noreply, poll_usage(state)}
  end

  # The in-flight usage-read Task, landing. Matched (and demonitored) before
  # the subscriber `:DOWN` clause below, which would otherwise also match this
  # shape.
  def handle_info({ref, result}, %{usage_task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | usage_task_ref: nil}

    case result do
      {:ok, totals} ->
        publish_usage(state, totals)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{usage_task_ref: ref} = state)
      when is_reference(ref) do
    {:noreply, %{state | usage_task_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: close_stream(state)

  # -- stream plumbing --------------------------------------------------------

  defp open_stream(state) do
    File.mkdir_p!(Path.dirname(state.path))
    File.touch!(state.path)

    # Recorded *before* the pipe is enabled: everything the pipe subsequently
    # catches is also in the snapshot, so the seam can only overlap (§4.5).
    base = file_size(state.path)

    with {:ok, %{snapshot: snapshot}} <- start_or_adopt(state),
         {:ok, fd} <- :file.open(state.path, [:read, :binary, :raw]),
         {:ok, _} <- :file.position(fd, base) do
      {:ok,
       %{
         state
         | fd: fd,
           seq: base,
           ring_base: base,
           pending_snapshot: snapshot,
           transcript_handle: open_transcript(state.id)
       }}
    end
  end

  # Best-effort, same posture as the old per-tick `Transcript.append/3`: a
  # transcript file that fails to open must never stop the pane from working.
  # Opened once here instead of once per poll tick (bd-5pelo2 finding 3) — the
  # fd, and the one-time `0600`/`0700` mode set, are held in reader state for
  # the reader's lifetime.
  defp open_transcript(id) do
    case Transcript.open(id) do
      {:ok, handle} ->
        handle

      {:error, reason} ->
        Logger.warning("Sessions.Stream #{id}: transcript open failed: #{inspect(reason)}")
        nil
    end
  end

  # After an `arbiter` restart the `cat` tmux spawned is still running in the
  # session's own scope and the file is still growing. Re-piping would work but
  # would needlessly churn the pane; adopting the live pipe is both cheaper and
  # the thing that makes cross-restart resume gapless.
  defp start_or_adopt(state) do
    if state.terminal.streaming?(state.session, state.opts) do
      with {:ok, snapshot} <- state.terminal.snapshot(state.session, state.opts) do
        {:ok, %{snapshot: snapshot}}
      end
    else
      state.terminal.start_stream(state.session, state.path, state.opts)
    end
  end

  # No `terminal.stop_stream/2` call here: the tmux pipe is no longer this
  # reader's to close (bd-5pelo2 finding 1). It is a session-lifetime
  # resource now — it keeps writing to `state.path` for as long as the
  # session itself is running, including every stretch this reader is not
  # (an `arbiter` restart, or simply nobody attached), and a later reader
  # adopts it via `start_or_adopt/1` rather than re-piping. The pane's own
  # teardown (`tmux kill-session`, in `Arbiter.Sessions.kill/2` and the
  # dead-session detection below) is what actually ends it.
  defp close_stream(%{fd: nil} = state), do: flush_transcript(state)

  defp close_stream(state) do
    _ = :file.close(state.fd)
    flush_transcript(%{state | fd: nil})
  end

  # The redaction hold-back buffer (bd-5pelo2 finding 2, round 2 finding 1)
  # can be holding up to `@max_hold_bytes` unwritten bytes — flush them,
  # as-is, since nothing more is coming for this reader to join them against.
  defp flush_transcript(state) do
    handle =
      if state.transcript_tail == <<>> do
        state.transcript_handle
      else
        write_transcript(state.transcript_handle, state.transcript_tail, state.redact_values)
      end

    if handle, do: Transcript.close(handle)
    %{state | transcript_handle: nil, transcript_tail: <<>>}
  end

  defp write_transcript(nil, _data, _redact_values), do: nil

  defp write_transcript(handle, data, redact_values) do
    Transcript.append_open(handle, data, redact_values)
  end

  defp pump(%{fd: nil} = state), do: state

  defp pump(state) do
    case :file.read(state.fd, state.config.read_chunk_bytes) do
      {:ok, data} when byte_size(data) > 0 ->
        state |> push_frame(data) |> pump_more(byte_size(data))

      _ ->
        state
    end
  end

  # One read per tick is the coalescing rule (§5.3 item 1); a read that filled
  # its buffer means more is already waiting, and waiting a whole tick for it
  # would let the file run ahead of the client under load.
  defp pump_more(state, read) do
    if read == state.config.read_chunk_bytes, do: pump(state), else: state
  end

  defp push_frame(state, data) do
    seq = state.seq + byte_size(data)
    frame = Frame.encode(seq, data)

    state
    |> record_transcript(data)
    |> Map.put(:seq, seq)
    |> ring_push(seq, data)
    |> deliver(frame)
    |> touch_turn()
  end

  # A secret can straddle a poll tick's chunk boundary — an operator *typing*
  # (rather than pasting) a token delivers it a few bytes per 25ms tick, so no
  # single chunk ever contains a full match (bd-5pelo2 finding 2; the same
  # hazard `Arbiter.Worker.SessionArchive` already documents and avoids for
  # the JSONL side by reading the whole file before redacting — impossible
  # here, since the PTY chunking is unavoidable). A *fixed-size* tail window
  # doesn't fix this (bd-5pelo2 round 2 finding 1): redaction only ever sees
  # `writable` = combined-minus-tail, so the held-back bytes are never
  # look-ahead for a match starting in `writable` — a token that outlives the
  # window one byte at a time is never whole in either write.
  #
  # Cutting at *any* separator byte doesn't fix this either (bd-5pelo2 round 3
  # finding 1): two of `Arbiter.Redaction.redact_patterns/1`'s patterns are
  # not unbroken token runs — `Bearer\s+<token>` contains a space, and a PEM
  # block spans newlines by construction — so a cut at, say, the space inside
  # `Bearer <token>` splits exactly the match it was meant to protect.
  #
  # Cut at a **newline** instead. No supported pattern except the PEM block
  # spans a newline, so a same-line match (including `Bearer <token>`) is
  # always either wholly before the cut or wholly after it — never split.
  # Bounded by `@max_hold_bytes` so a pathological run with no newline (huge
  # base64 blob, binary noise) still drains instead of buffering forever.
  #
  # The PEM block is the one pattern a newline cut cannot protect on its own,
  # so it gets its own guard: if the candidate writable portion contains a
  # `-----BEGIN` with no matching `-----END` after it, the cut is pulled back
  # to the start of that marker and everything from there is held instead —
  # same `@max_hold_bytes` bound applies.
  @max_hold_bytes 8192
  @pem_begin "-----BEGIN"
  @pem_end "-----END"

  defp record_transcript(state, data) do
    combined = state.transcript_tail <> data
    {writable, tail} = split_tail(combined)

    handle =
      if writable == <<>> do
        state.transcript_handle
      else
        write_transcript(state.transcript_handle, writable, state.redact_values)
      end

    %{state | transcript_handle: handle, transcript_tail: tail}
  end

  defp split_tail(data) do
    case last_newline_index(data) do
      nil ->
        force_cut(data)

      idx ->
        hold_size = byte_size(data) - (idx + 1)

        if hold_size > @max_hold_bytes do
          force_cut(data)
        else
          adjust_for_open_pem(data, idx + 1)
        end
    end
  end

  defp force_cut(data) when byte_size(data) <= @max_hold_bytes, do: {<<>>, data}

  defp force_cut(data) do
    cut = byte_size(data) - @max_hold_bytes
    {:binary.part(data, 0, cut), :binary.part(data, cut, @max_hold_bytes)}
  end

  defp adjust_for_open_pem(data, cut) do
    candidate = :binary.part(data, 0, cut)

    case open_pem_start(candidate) do
      nil ->
        {candidate, :binary.part(data, cut, byte_size(data) - cut)}

      begin_idx ->
        hold_size = byte_size(data) - begin_idx

        if hold_size > @max_hold_bytes do
          force_cut(data)
        else
          {:binary.part(data, 0, begin_idx), :binary.part(data, begin_idx, hold_size)}
        end
    end
  end

  # Byte offset of a `-----BEGIN` marker in `data` with no matching
  # `-----END` after it, or `nil` if the buffer holds no unterminated PEM
  # marker. Only the last `-----BEGIN` needs checking: valid PEM blocks don't
  # overlap, so if the last one is closed, every earlier one is too.
  defp open_pem_start(data) do
    case :binary.matches(data, @pem_begin) do
      [] ->
        nil

      matches ->
        {begin_idx, _len} = List.last(matches)
        rest = :binary.part(data, begin_idx, byte_size(data) - begin_idx)

        if :binary.match(rest, @pem_end) == :nomatch, do: begin_idx, else: nil
    end
  end

  # Rightmost newline in `data` — the one boundary no supported credential
  # pattern (other than the separately-guarded PEM block) can straddle.
  # `nil` when there is none within `@max_hold_bytes` of the end. Scans
  # backward from the end instead of collecting every newline's position
  # (bd-5pelo2 round 3 finding 3) — O(hold size), not O(chunk size), and
  # allocates nothing.
  defp last_newline_index(data) do
    limit = max(byte_size(data) - @max_hold_bytes - 1, -1)
    scan_back_newline(data, byte_size(data) - 1, limit)
  end

  defp scan_back_newline(_data, i, limit) when i <= limit, do: nil

  defp scan_back_newline(data, i, limit) do
    case :binary.at(data, i) do
      ?\n -> i
      _ -> scan_back_newline(data, i - 1, limit)
    end
  end

  # The idle-deadline's other input (§4.6 item 2): the pane actually produced
  # output, whether or not anyone is attached to watch it — this is what
  # keeps an unattended agent mid-tool-loop off the idle sweep. Throttled
  # against the 25ms poll tick; a DB write per byte read would be pointless
  # load for a signal only ever compared against a TTL measured in hours.
  @touch_turn_min_interval_ms 60_000
  defp touch_turn(state) do
    now_ms = System.monotonic_time(:millisecond)

    if is_nil(state.last_turn_touch_ms) or
         now_ms - state.last_turn_touch_ms >= @touch_turn_min_interval_ms do
      _ = Sessions.touch_turn(state.session)
      %{state | last_turn_touch_ms: now_ms}
    else
      state
    end
  end

  defp deliver(state, frame) do
    size = byte_size(frame)

    subs =
      Map.new(state.subs, fn {pid, sub} ->
        cond do
          sub.mode == :dropping ->
            {pid, sub}

          sub.inflight >= state.config.high_water_bytes ->
            {pid, %{sub | mode: :dropping}}

          true ->
            send(pid, {:session_stdout, state.id, frame})
            {pid, %{sub | inflight: sub.inflight + size}}
        end
      end)

    %{state | subs: subs}
  end

  # §5.3 item 2: discard the backlog, push one snapshot, resume live.
  defp repaint(state, pid) do
    case state.terminal.snapshot(state.session, state.opts) do
      {:ok, data} ->
        send(pid, {:session_snapshot, state.id, %{seq: state.seq, data: data}})

        put_in(state.subs[pid], %{
          state.subs[pid]
          | mode: :live,
            inflight: byte_size(data),
            needs_snapshot: false
        })

      {:error, reason} ->
        Logger.warning(
          "Sessions.Stream #{state.id}: snapshot for repaint failed: #{inspect(reason)}"
        )

        state
    end
  end

  # -- ring and resume --------------------------------------------------------

  defp ring_push(state, seq, data) do
    ring = :queue.in({seq, data}, state.ring)

    trim(%{
      state
      | ring: ring,
        ring_bytes: state.ring_bytes + byte_size(data) + Frame.header_size()
    })
  end

  defp trim(state) when state.ring_bytes <= 0, do: state

  defp trim(state) do
    if state.ring_bytes > state.config.ring_bytes do
      case :queue.out(state.ring) do
        {{:value, {seq, data}}, ring} ->
          trim(%{
            state
            | ring: ring,
              ring_bytes: state.ring_bytes - byte_size(data) - Frame.header_size(),
              ring_base: seq
          })

        {:empty, _ring} ->
          state
      end
    else
      state
    end
  end

  defp resume(state, last_seq) do
    case replay(state, last_seq) do
      {:ok, frames} ->
        state = %{state | pending_snapshot: nil}
        {%{seq: state.seq, mode: :resumed, snapshot: nil, replay: frames}, state}

      :snapshot ->
        {snapshot, state} = take_snapshot(state)
        {%{seq: state.seq, mode: :snapshot, snapshot: snapshot, replay: []}, state}
    end
  end

  defp replay(_state, nil), do: :snapshot

  defp replay(state, last_seq) when is_integer(last_seq) do
    cond do
      last_seq < 0 or last_seq > state.seq -> :snapshot
      state.seq - last_seq > state.config.max_replay_bytes -> :snapshot
      last_seq >= state.ring_base -> {:ok, replay_from_ring(state, last_seq)}
      true -> replay_from_file(state, last_seq)
    end
  end

  defp replay(_state, _last_seq), do: :snapshot

  defp replay_from_ring(state, last_seq) do
    state.ring
    |> :queue.to_list()
    |> Enum.filter(fn {seq, _data} -> seq > last_seq end)
    |> Enum.map(fn {seq, data} ->
      # The frame `last_seq` landed inside is replayed from the next byte on.
      overlap = last_seq - (seq - byte_size(data))

      if overlap > 0,
        do: Frame.encode(seq, :binary.part(data, overlap, byte_size(data) - overlap)),
        else: Frame.encode(seq, data)
    end)
  end

  # The ring has aged out, but `seq` is a file offset, so the pipe file itself
  # can still answer — which is what keeps a reconnect after an `arbiter`
  # restart gapless rather than a repaint.
  defp replay_from_file(state, last_seq) do
    length = state.seq - last_seq

    case :file.pread(state.fd, last_seq, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, [Frame.encode(state.seq, data)]}
      _ -> :snapshot
    end
  end

  defp take_snapshot(%{pending_snapshot: snapshot} = state) when is_binary(snapshot) do
    {snapshot, %{state | pending_snapshot: nil}}
  end

  defp take_snapshot(state) do
    case state.terminal.snapshot(state.session, state.opts) do
      {:ok, data} ->
        {data, state}

      {:error, reason} ->
        Logger.warning("Sessions.Stream #{state.id}: snapshot failed: #{inspect(reason)}")
        {"", state}
    end
  end

  # -- subscribers, meta, geometry --------------------------------------------

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subs, pid) do
      {nil, _subs} ->
        state

      {sub, subs} ->
        Process.demonitor(sub.ref, [:flush])
        state = %{state | subs: subs}
        broadcast_meta(state)
        state
    end
  end

  defp geometry?(cols, rows) do
    is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0
  end

  defp apply_resize(state, cols, rows) do
    if {cols, rows} == {state.cols, state.rows} do
      state
    else
      case state.terminal.resize(state.session, cols, rows, state.opts) do
        :ok ->
          %{state | cols: cols, rows: rows}

        {:error, reason} ->
          Logger.warning("Sessions.Stream #{state.id}: resize failed: #{inspect(reason)}")
          state
      end
    end
  end

  defp refresh_geometry(state) do
    case state.terminal.geometry(state.session, state.opts) do
      {:ok, %{cols: cols, rows: rows, title: title}} ->
        %{state | cols: cols, rows: rows, title: title}

      {:error, _reason} ->
        state
    end
  end

  defp meta_payload(state) do
    %{
      cols: state.cols,
      rows: state.rows,
      attached_clients: map_size(state.subs),
      title: state.title
    }
  end

  defp broadcast_meta(state, opts \\ []) do
    except = Keyword.get(opts, :except)
    payload = meta_payload(state)

    for {pid, _sub} <- state.subs, pid != except do
      send(pid, {:session_meta, state.id, payload})
    end

    :ok
  end

  defp broadcast(state, message) do
    for {pid, _sub} <- state.subs, do: send(pid, message)
    :ok
  end

  # -- live cost HUD (§7.5, phase 7) -------------------------------------------

  # Nobody watching: skip the file read entirely rather than tailing a
  # session nothing is attached to.
  defp poll_usage(%{subs: subs} = state) when map_size(subs) == 0, do: state

  # A previous tick's read is still in flight — never start a second one
  # concurrently (the file only grows every ~2s; there is nothing new to read
  # before the first one lands).
  defp poll_usage(%{usage_task_ref: ref} = state) when is_reference(ref), do: state

  defp poll_usage(%{session: session} = state) do
    case usage_source(session) do
      {:ok, provider_session_id, path, session} ->
        maybe_read_usage(%{state | session: session}, path, provider_session_id)

      :not_found ->
        state
    end
  end

  # `session.provider_session_id` resolves to a file: use it, *unless* a
  # newer `*.jsonl` has since appeared in the same config dir. A rollover
  # (`--resume`/compaction) does not delete the old file — the CLI starts
  # appending to a new `<sid>.jsonl` alongside it — so `locate/2` keeps
  # resolving the stale id forever and this reader would otherwise go dark
  # for the rest of the session. If `locate/2` fails outright (the file was
  # actually removed), fall through to discovery the same way.
  defp usage_source(%{provider_session_id: id} = session) when is_binary(id) and id != "" do
    case ClaudeSessionFile.locate(session.config_dir, id) do
      {:ok, path} -> usage_source_or_newer(session, id, path)
      :not_found -> discover_usage_source(session)
    end
  end

  defp usage_source(session), do: discover_usage_source(session)

  defp usage_source_or_newer(session, id, path) do
    case discover_provider_session_file(session.config_dir) do
      {:ok, ^id, _path} ->
        {:ok, id, path, session}

      {:ok, newer_id, newer_path} ->
        if jsonl_mtime(newer_path) > jsonl_mtime(path) do
          {:ok, newer_id, newer_path, persist_provider_session(session, newer_id)}
        else
          {:ok, id, path, session}
        end

      :not_found ->
        {:ok, id, path, session}
    end
  end

  # `provider_session_id` is nullable at launch (the CLI picks it). Assume the
  # newest `*.jsonl` under the session's own config dir is the file the CLI is
  # currently appending to, and persist the discovery back onto the row
  # (best-effort: a failed write doesn't stop this tick from using the id it
  # just found — it's `Sessions.usage_events/1` that needs the column, and
  # that can wait for the next successful tick).
  defp discover_usage_source(session) do
    case discover_provider_session_file(session.config_dir) do
      {:ok, provider_session_id, path} ->
        {:ok, provider_session_id, path, persist_provider_session(session, provider_session_id)}

      :not_found ->
        :not_found
    end
  end

  defp discover_provider_session_file(config_dir)
       when is_binary(config_dir) and config_dir != "" do
    case Path.wildcard(Path.join([config_dir, "projects", "*", "*.jsonl"])) do
      [] ->
        :not_found

      paths ->
        path = Enum.max_by(paths, &jsonl_mtime/1)
        {:ok, Path.basename(path, ".jsonl"), path}
    end
  end

  defp discover_provider_session_file(_config_dir), do: :not_found

  defp jsonl_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp persist_provider_session(session, provider_session_id) do
    case Sessions.record_provider_session(session, provider_session_id) do
      {:ok, updated} -> updated
      _ -> session
    end
  rescue
    _ -> session
  end

  # Skip the (relatively expensive) full parse when the file hasn't changed
  # since the last read, and run the read that does happen off the GenServer
  # in a short-lived Task so decoding a multi-MB transcript never blocks the
  # 25ms PTY poll or a synchronous `attach`/`send_input`/`snapshot` call.
  defp maybe_read_usage(state, path, provider_session_id) do
    case file_stat_key(path) do
      nil ->
        state

      stat when stat == state.usage_file_stat ->
        state

      stat ->
        %Task{ref: ref} =
          Task.Supervisor.async_nolink(Arbiter.TaskSupervisor, fn ->
            ClaudeSessionFile.read_totals(path, session_id: provider_session_id)
          end)

        %{state | usage_task_ref: ref, usage_file_stat: stat}
    end
  end

  defp file_stat_key(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} -> {size, mtime}
      _ -> nil
    end
  end

  defp publish_usage(state, totals) do
    Sessions.broadcast_usage(state.id, %{
      tokens_in: totals.tokens_in,
      tokens_out: totals.tokens_out,
      cache_creation: totals.cache_creation_tokens,
      cache_read: totals.cache_read_tokens,
      cost_usd: totals.cost_usd,
      model: totals.model,
      estimated: totals.cost_source == :estimated
    })
  end

  # -- misc -------------------------------------------------------------------

  defp config(opts) do
    configured = Application.get_env(:arbiter, __MODULE__, [])

    @defaults
    |> Keyword.merge(configured)
    |> Keyword.merge(Keyword.take(opts, Keyword.keys(@defaults)))
    |> Map.new()
  end

  defp pipe_path(session, opts) do
    case Keyword.get(opts, :pipe_dir) do
      nil ->
        case Naming.pipe_path(session.id) do
          {:ok, path} ->
            path

          {:error, reason} ->
            raise ArgumentError, "session pipe path unavailable: #{inspect(reason)}"
        end

      dir ->
        Path.join(dir, Naming.pipe_basename(session.id))
    end
  end

  # Resolved once, at reader start, and reused for every frame's transcript
  # write (`Arbiter.Sessions.Transcript.append/3`) rather than re-fetched: a
  # DB round trip per PTY poll tick would compete with the tick's own 25ms
  # budget. `:redact_values` is a test seam so a suite need not fixture a
  # whole workspace to assert redaction.
  defp redact_values(session, opts) do
    case Keyword.fetch(opts, :redact_values) do
      {:ok, values} -> values
      :error -> Transcript.redact_values_for(session)
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp schedule(_message, interval) when interval in [nil, :never], do: nil
  defp schedule(message, interval), do: Process.send_after(self(), message, interval)
end
