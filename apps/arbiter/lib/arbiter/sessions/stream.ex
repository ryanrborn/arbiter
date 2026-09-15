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
  started on first attach and stopped when the last client leaves. The
  property the RFC actually cares about is preserved exactly — a detach or an
  `arbiter` restart drops the reader, never the session.

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
        linger_ms: 5_000,             # reader lifetime after the last detach
        snapshot_lines: 2_000

  Every key is also accepted as an option to `attach/2`, which is how the
  suite drives it. Configuration is fixed by the **first** attach for the
  reader's lifetime.

  ## Live cost HUD (§7.5, phase 7)

  Same reader, one more timer: every `usage_poll_interval_ms` (~2s), while at
  least one client is attached, it re-reads the session's on-disk JSONL with
  `Arbiter.Usage.ClaudeSessionFile.read_totals/2` — the same reconciliation
  arithmetic `Arbiter.Sessions.UsageIngest` already uses, reused rather than
  reimplemented — and publishes the *delta* since the previous tick as a
  `usage` event on `Arbiter.Sessions.usage_topic/1`. `ArbiterWeb.SessionChannel`
  subscribes to that topic independently of this reader's own `subs` (it is
  PubSub, not a direct send), so multiple attached tabs share one tailer.

  Token counts in the payload are deltas — "what changed since the last
  push" — but `cost_usd` is the file's latest cumulative figure: `cost-state`
  records are periodic (often absent entirely on 2.1.270+, see
  `ClaudeSessionFile`'s moduledoc), so there is rarely a *new* dollar amount
  to diff, only the most recently known total. `estimated` mirrors
  `totals.cost_source != :cost_state` — true whenever that total came from
  `Arbiter.Usage.ClaudePricing`'s token-based estimate rather than the CLI's
  own accounting, which is the HUD's "estimated" marker (AC 1).

  This reads `session.config_dir` / `session.provider_session_id` as they
  were at the reader's own start (or last resume) rather than re-fetching the
  row every tick — cheap, and consistent with every other use of
  `state.session` in this module. A mid-session provider-id rollover (§7.5's
  "wrinkle") is therefore a gap the *authoritative* reconciliation
  (`Arbiter.Sessions.UsageIngest`) closes on its own sweep; the live HUD is
  documented as "cheap, approximate" for exactly this reason.
  """

  use GenServer

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session
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
    usage_poll_interval_ms: 2_000,
    linger_ms: 5_000
  ]

  # The zero-baseline a fresh reader diffs its first usage poll against —
  # nothing has been shown yet, so the first tick's delta is the file's
  # whole in-window total.
  @blank_usage_totals %{
    tokens_in: 0,
    tokens_out: 0,
    cache_creation_tokens: 0,
    cache_read_tokens: 0
  }

  # Rounds `attach/2` will re-resolve the reader over before giving up. Three
  # is generous: the window it covers is the registry's handling of one
  # `:DOWN`, not any kind of real work.
  @attach_attempts 3
  @attach_retry_ms 5

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

  When the last subscriber leaves, the reader closes the pipe and stops —
  after `:linger_ms`, so that a browser reload reattaches to the same `seq`
  space instead of being repainted.
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
      linger_timer: nil,
      last_turn_touch_ms: nil,
      usage_last: @blank_usage_totals
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
    state = cancel_linger(state)

    state =
      if Map.has_key?(state.subs, pid) do
        state
      else
        ref = Process.monitor(pid)

        put_in(state.subs[pid], %{
          ref: ref,
          inflight: 0,
          mode: :live,
          needs_snapshot: false
        })
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
    state = drop_subscriber(state, pid)

    if map_size(state.subs) == 0 and state.config.linger_ms == 0 do
      {:stop, :normal, :ok, close_stream(state)}
    else
      {:reply, :ok, maybe_linger(state)}
    end
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
      {:noreply, refresh_geometry(state)}
    else
      # Drain whatever the pane wrote on its way out before announcing it.
      state = pump(state)
      broadcast(state, {:session_exit, state.id, %{code: nil, reason: "exited"}})
      {:stop, :normal, close_stream(state)}
    end
  end

  def handle_info(:usage_poll, state) do
    schedule(:usage_poll, state.config.usage_poll_interval_ms)
    {:noreply, poll_usage(state)}
  end

  def handle_info(:linger_expired, state) do
    if map_size(state.subs) == 0 do
      {:stop, :normal, close_stream(state)}
    else
      {:noreply, %{state | linger_timer: nil}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = drop_subscriber(state, pid)

    if map_size(state.subs) == 0 and state.config.linger_ms == 0 do
      {:stop, :normal, close_stream(state)}
    else
      {:noreply, maybe_linger(state)}
    end
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
           pending_snapshot: snapshot
       }}
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

  defp close_stream(%{fd: nil} = state), do: state

  defp close_stream(state) do
    _ = state.terminal.stop_stream(state.session, state.opts)
    _ = :file.close(state.fd)
    %{state | fd: nil}
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
    |> Map.put(:seq, seq)
    |> ring_push(seq, data)
    |> deliver(frame)
    |> touch_turn()
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

  defp poll_usage(%{session: session} = state) do
    with provider_session_id when is_binary(provider_session_id) <-
           session.provider_session_id,
         {:ok, path} <- ClaudeSessionFile.locate(session.config_dir, provider_session_id),
         {:ok, totals} <-
           ClaudeSessionFile.read_totals(path, session_id: provider_session_id) do
      publish_usage_delta(state, totals)
      %{state | usage_last: usage_snapshot(totals)}
    else
      _ -> state
    end
  end

  defp publish_usage_delta(state, totals) do
    last = state.usage_last

    Sessions.broadcast_usage(state.id, %{
      tokens_in: usage_delta(totals.tokens_in, last.tokens_in),
      tokens_out: usage_delta(totals.tokens_out, last.tokens_out),
      cache_creation: usage_delta(totals.cache_creation_tokens, last.cache_creation_tokens),
      cache_read: usage_delta(totals.cache_read_tokens, last.cache_read_tokens),
      cost_usd: totals.cost_usd,
      model: totals.model,
      estimated: totals.cost_source != :cost_state
    })
  end

  defp usage_delta(now, prev) when is_integer(now) and is_integer(prev), do: max(now - prev, 0)
  defp usage_delta(_now, _prev), do: 0

  defp usage_snapshot(totals) do
    %{
      tokens_in: totals.tokens_in,
      tokens_out: totals.tokens_out,
      cache_creation_tokens: totals.cache_creation_tokens,
      cache_read_tokens: totals.cache_read_tokens
    }
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

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp schedule(_message, interval) when interval in [nil, :never], do: nil
  defp schedule(message, interval), do: Process.send_after(self(), message, interval)

  defp maybe_linger(state) do
    if map_size(state.subs) == 0 and is_nil(state.linger_timer) do
      %{state | linger_timer: schedule(:linger_expired, state.config.linger_ms)}
    else
      state
    end
  end

  defp cancel_linger(%{linger_timer: nil} = state), do: state

  defp cancel_linger(state) do
    Process.cancel_timer(state.linger_timer)
    %{state | linger_timer: nil}
  end
end
