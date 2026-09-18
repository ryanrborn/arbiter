defmodule ArbiterWeb.SessionChannel do
  @moduledoc """
  RFC §5.2's message envelope, verbatim (bd-3ymdvi, phase 4 of
  `docs/browser-hosted-coordinator-sessions.md`).

  One channel process per attached browser tab, on topic `session:<id>`. It is
  a **translation layer**: the protocol's state — sequence numbers, the replay
  ring, backpressure, geometry — lives in `Arbiter.Sessions.Stream`, and this
  module turns its messages into channel events and back. That split is what
  lets the transport be tested headlessly and lets a second transport (a CLI,
  a second UI) exist later without reimplementing the protocol.

  ## Transcript mode (bd-3tf4oo)

  A session that has *ended* has no reader to attach to, but it usually has a
  persisted raw transcript (`Arbiter.Sessions.Transcript`, §11). Joining with
  `%{"mode" => "transcript"}` replays that file instead of attaching: the
  bytes go out as the same `snapshot` event a live attach sends, so the
  browser paints a finished session through the terminal's existing repaint
  path rather than through a second renderer. The join reply carries the
  replay's bounds (`total_bytes`, `replay_bytes`, `truncated?`) and the
  session's own end reason and `ended_at`.

  Such a channel is a *reader of a file*, and everything that would make it
  look otherwise is refused with `read_only`: stdin, resize, redraw and kill.
  It starts no reader process, subscribes to no usage feed, pushes no `meta`
  and never stamps `last_client_at` — an ended session has no idle deadline
  left to postpone. A transcript that is missing (swept by
  `Arbiter.Sessions.TranscriptRetention`, never captured, or empty) refuses
  the join with `transcript_unavailable` and the reason, which the dock
  renders as an explicit empty state rather than a blank terminal.

  ## Client → server

  | Event | Payload | Notes |
  |---|---|---|
  | `join` | `%{last_seq \\| nil, cols, rows}` | session id comes from the topic |
  | `stdin` | `{:binary, frame}` | `Arbiter.Sessions.Frame`; raw bytes |
  | `resize` | `%{cols, rows}` | debounced client-side |
  | `redraw` | `%{}` | make the agent repaint; see `Arbiter.Sessions.Stream.redraw/2` |
  | `detach` | `%{}` | leave the session running; the reader is dropped |
  | `kill` | `%{confirm: true}` | via `Arbiter.Sessions.kill/2` |
  | `ping` | `%{ts}` | liveness/RTT for the HUD |

  ## Server → client

  | Event | Payload | Notes |
  |---|---|---|
  | `snapshot` | `%{seq, data}` | ANSI-preserving scrollback |
  | `stdout` | `{:binary, frame}` | live output, `seq` framed in |
  | `exit` | `%{code, reason}` | the agent exited |
  | `meta` | `%{cols, rows, attached_clients, title}` | reconciles another client's resize |
  | `usage` | `%{tokens_in, …}` | HUD feed (§7.5, phase 7) |
  | `error` | `%{code, detail}` | e.g. `session_gone`, `bridge_unavailable` |

  ## Why stdin and stdout are binary

  A terminal stream splits multi-byte UTF-8 and escape sequences across reads.
  Decoding at the transport corrupts them permanently, so neither direction is
  ever JSON-wrapped or validated as text here — `Arbiter.Sessions.Frame` puts
  `seq` in front of the bytes and nothing touches the bytes themselves.

  ## stdin sequence numbers

  Client stdin frames carry the client's own monotonic counter. A reconnecting
  client that re-sends its tail would otherwise type the same keystrokes into
  the pane twice, which for a terminal is not a cosmetic bug — it is a second
  `rm` with a second newline. Anything at or below the highest seq already
  seen on **this** channel is dropped. The counter is per channel process, so
  a genuinely new connection starting again at 1 is not affected.

  ## Join ordering

  A client may rely on the first thing it receives after a successful `join`
  being its `snapshot` (or its replay frames) — never a live `stdout`. The
  reader starts streaming to this pid during the attach call, so frames can
  land before the join flush runs; they are held and delivered in order
  afterwards rather than jumping the queue. Without that, a client would have
  to repaint backwards over bytes it had already drawn.

  ## Geometry

  `cols`/`rows` are only honoured when both are positive integers. Anything
  else — absent, non-integer, or the `0` a browser reports for a terminal it
  has not laid out yet — means "no opinion", and the pane keeps its size.

  ## Backpressure

  Every pushed frame is acknowledged back to the reader
  (`Arbiter.Sessions.Stream.ack/3`) so a client the socket cannot keep up with
  stops receiving frames and is repainted with one snapshot when it recovers,
  rather than growing an unbounded mailbox (§5.3 item 2).
  """

  use Phoenix.Channel

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Stream
  alias Arbiter.Sessions.TranscriptReplay

  require Logger

  # How often an attached channel re-stamps `last_client_at` (§4.6 item 2) —
  # short enough that `Arbiter.Sessions.IdleReaper`'s 24h default TTL never
  # sees a continuously-attached client as idle, long enough not to matter as
  # write load.
  @touch_client_interval_ms 5 * 60_000

  @impl true
  def join("session:" <> session_id, %{"mode" => "transcript"}, socket) do
    with {:ok, session} <- fetch_session(session_id),
         {:ok, tail} <- read_transcript(session) do
      socket =
        socket
        |> assign(:session_id, session_id)
        |> assign(:mode, :transcript)
        |> assign(:replay, tail)

      send(self(), :after_join_transcript)

      {:ok,
       %{
         mode: "transcript",
         # The replay's own end offset, so a client's `last_seq` arithmetic
         # starts from the same place a live snapshot's would.
         seq: tail.end_offset,
         start_offset: tail.start_offset,
         end_offset: tail.end_offset,
         total_bytes: tail.total_bytes,
         replay_bytes: byte_size(tail.data),
         truncated?: tail.truncated?,
         end_reason: session.end_reason,
         ended_at: session.ended_at
       }, socket}
    else
      {:error, :session_gone} ->
        {:error, %{code: "session_gone", detail: "no session #{session_id}"}}

      {:error, {:transcript_unavailable, reason}} ->
        {:error,
         %{
           code: "transcript_unavailable",
           reason: to_string(reason),
           detail: "no transcript for #{session_id} (#{reason})"
         }}
    end
  end

  def join("session:" <> session_id, params, socket) do
    with {:ok, session} <- fetch_live_session(session_id),
         {:ok, attached} <- attach(session, params) do
      socket =
        socket
        |> assign(:session_id, session_id)
        |> assign(:mode, :live)
        |> assign(:attached, attached)
        |> assign(:last_stdin_seq, 0)
        |> assign(:joined?, false)
        |> assign(:pending, [])

      # A client is now attached — the idle-deadline's `last_client_at` input
      # (§4.6 item 2). Stamped again on a timer below so a client that stays
      # attached without ever rejoining does not go stale after 24h.
      _ = Sessions.touch_client(session)
      Process.send_after(self(), :touch_client, @touch_client_interval_ms)

      send(self(), :after_join)

      {:ok,
       %{
         seq: attached.seq,
         mode: Atom.to_string(attached.mode),
         # Whether *this* join changed the pane's size. The snapshot below was
         # captured in the same breath as that resize, so a `true` here means
         # the client is about to paint content the pane reflowed rather than
         # content the agent redrew (bd-14b11h).
         resized: attached.resized
       }, socket}
    else
      {:error, :session_gone} ->
        {:error, %{code: "session_gone", detail: "no live session #{session_id}"}}

      {:error, reason} ->
        {:error, %{code: "bridge_unavailable", detail: inspect(reason)}}
    end
  end

  def join(topic, _params, _socket) do
    {:error, %{code: "bad_topic", detail: topic}}
  end

  @impl true
  def handle_info(:after_join_transcript, socket) do
    tail = socket.assigns.replay

    # The same event, with the same shape, a live attach's scrollback arrives
    # on (`dispatch({:session_snapshot, ...})` below) — one renderer.
    push(socket, "snapshot", %{seq: tail.end_offset, data: tail.data})

    {:noreply, assign(socket, :replay, %{tail | data: ""})}
  end

  def handle_info(:after_join, socket) do
    %{attached: attached, session_id: session_id} = socket.assigns

    case attached.mode do
      :snapshot ->
        push(socket, "snapshot", %{seq: attached.seq, data: attached.snapshot})

      :resumed ->
        # Exactly the missed frames, in order, on the same binary path as live
        # output — a resuming client has one code path, not two.
        Enum.each(attached.replay, &push_frame(socket, session_id, &1))
    end

    push(socket, "meta", attached.meta)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.usage_topic(session_id))

    socket
    |> assign(:attached, %{attached | replay: [], snapshot: nil})
    |> assign(:joined?, true)
    |> drain_pending()
  end

  def handle_info({:session_stdout, _id, _frame} = message, socket),
    do: stream_event(message, socket)

  def handle_info({:session_snapshot, _id, _payload} = message, socket),
    do: stream_event(message, socket)

  def handle_info({:session_meta, _id, _meta} = message, socket),
    do: stream_event(message, socket)

  def handle_info({:session_exit, _id, _payload} = message, socket),
    do: stream_event(message, socket)

  def handle_info({:session_usage, _id, _payload} = message, socket),
    do: stream_event(message, socket)

  def handle_info({:session_error, _id, _payload} = message, socket),
    do: stream_event(message, socket)

  def handle_info(:touch_client, socket) do
    case Sessions.get(socket.assigns.session_id) do
      {:ok, session} -> Sessions.touch_client(session)
      {:error, :not_found} -> :ok
    end

    Process.send_after(self(), :touch_client, @touch_client_interval_ms)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A transcript channel is a file being read, not a pane. Every verb that
  # would write to a pane (or end one) stops here, before it can reach a
  # reader that does not exist — and says why, rather than failing silently.
  @impl true
  def handle_in("stdin", _payload, %{assigns: %{mode: :transcript}} = socket) do
    push(socket, "error", %{code: "read_only", detail: "this is a replayed transcript"})
    {:noreply, socket}
  end

  def handle_in(event, _payload, %{assigns: %{mode: :transcript}} = socket)
      when event in ~w(resize redraw kill) do
    {:reply, {:error, %{code: "read_only", detail: "this is a replayed transcript"}}, socket}
  end

  def handle_in("stdin", {:binary, payload}, socket) do
    case Frame.decode(payload) do
      {:ok, seq, bytes} when seq > socket.assigns.last_stdin_seq ->
        case Stream.input(socket.assigns.session_id, bytes) do
          :ok ->
            {:noreply, assign(socket, :last_stdin_seq, seq)}

          {:error, reason} ->
            push(socket, "error", %{code: error_code(reason), detail: inspect(reason)})
            {:noreply, socket}
        end

      {:ok, _seq, _bytes} ->
        # A replayed frame from before a reconnect. Already typed; drop it.
        {:noreply, socket}

      {:error, :bad_frame} ->
        push(socket, "error", %{
          code: "bad_frame",
          detail: "stdin must be an ARB1-framed binary payload"
        })

        {:noreply, socket}
    end
  end

  def handle_in("stdin", _payload, socket) do
    push(socket, "error", %{
      code: "bad_frame",
      detail: "stdin must arrive as a binary frame, never JSON"
    })

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    case Stream.resize(socket.assigns.session_id, cols, rows) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{code: error_code(reason)}}, socket}
    end
  end

  def handle_in("resize", _payload, socket) do
    {:reply, {:error, %{code: "bad_payload", detail: "resize needs positive cols and rows"}},
     socket}
  end

  # The client is showing bytes the pane laid out for a geometry it no longer
  # has — a browser terminal whose join resized the pane (`resized` in the join
  # reply, bd-14b11h). Nothing it can do on its own fixes that: the content has
  # to come from the agent again.
  def handle_in("redraw", _payload, socket) do
    case Stream.redraw(socket.assigns.session_id) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{code: error_code(reason)}}, socket}
    end
  end

  def handle_in("detach", _payload, socket) do
    Stream.detach(socket.assigns.session_id)
    {:stop, {:shutdown, :detached}, {:ok, %{}}, socket}
  end

  def handle_in("kill", %{"confirm" => true}, socket) do
    session_id = socket.assigns.session_id

    case Sessions.kill(session_id, caller_session_id: socket.assigns[:caller_session_id]) do
      {:ok, _session} ->
        {:reply, :ok, socket}

      {:error, reason} ->
        code = error_code(reason)
        push(socket, "error", %{code: code, detail: inspect(reason)})
        {:reply, {:error, %{code: code, detail: inspect(reason)}}, socket}
    end
  end

  def handle_in("kill", _payload, socket) do
    {:reply, {:error, %{code: "confirmation_required", detail: "kill needs {\"confirm\": true}"}},
     socket}
  end

  def handle_in("ping", payload, socket) do
    {:reply, {:ok, %{ts: payload["ts"], server_ts: System.system_time(:millisecond)}}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{code: "unknown_event", detail: event}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:session_id] do
      nil -> :ok
      session_id -> Stream.detach(session_id)
    end
  end

  # -- internals --------------------------------------------------------------

  # Any session row at all, live or over — transcript mode reads a file, and
  # the file outlives the pane.
  defp fetch_session(session_id) do
    case Sessions.get(session_id) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :session_gone}
    end
  end

  # `describe/2` first, so an unavailable transcript is refused with *why* it
  # is unavailable rather than with a bare `enoent`; the read that follows can
  # still lose a race with the retention sweep, which reports the same way.
  defp read_transcript(session) do
    case TranscriptReplay.describe(session) do
      %{available?: true} ->
        case TranscriptReplay.read_tail(session.id) do
          {:ok, tail} -> {:ok, tail}
          {:error, _reason} -> {:error, {:transcript_unavailable, :retention_deleted}}
        end

      %{reason: reason} ->
        {:error, {:transcript_unavailable, reason}}
    end
  end

  defp fetch_live_session(session_id) do
    case Sessions.get(session_id) do
      {:ok, %{status: :ended}} -> {:error, :session_gone}
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :session_gone}
    end
  end

  defp attach(session, params) do
    Stream.attach(session,
      subscriber: self(),
      last_seq: non_neg_integer(params["last_seq"]),
      cols: positive_integer(params["cols"]),
      rows: positive_integer(params["rows"])
    )
  end

  # The join-ordering barrier.
  #
  # `Stream.attach/2` registers this pid as a subscriber *inside* the reader's
  # `GenServer.call`, so the reader's next poll can deliver a live frame before
  # `join/3` has got as far as `send(self(), :after_join)`. Pushing that frame
  # straight through would put a `seq` newer than the snapshot on the wire
  # ahead of it, and a client following the protocol would then repaint
  # backwards over bytes it had already rendered. So anything that arrives in
  # that window is held and drained, in arrival order, the moment the
  # snapshot/replay flush is done.
  defp stream_event(message, %{assigns: %{joined?: false}} = socket) do
    {:noreply, assign(socket, :pending, [message | socket.assigns.pending])}
  end

  defp stream_event(message, socket), do: dispatch(message, socket)

  defp drain_pending(socket) do
    drain(Enum.reverse(socket.assigns.pending), assign(socket, :pending, []))
  end

  defp drain([], socket), do: {:noreply, socket}

  defp drain([message | rest], socket) do
    case dispatch(message, socket) do
      {:noreply, socket} -> drain(rest, socket)
      stop -> stop
    end
  end

  defp dispatch({:session_stdout, session_id, frame}, socket) do
    push_frame(socket, session_id, frame)
    {:noreply, socket}
  end

  defp dispatch({:session_snapshot, _session_id, payload}, socket) do
    push(socket, "snapshot", payload)
    {:noreply, socket}
  end

  defp dispatch({:session_meta, _session_id, meta}, socket) do
    push(socket, "meta", meta)
    {:noreply, socket}
  end

  defp dispatch({:session_exit, _session_id, payload}, socket) do
    push(socket, "exit", payload)
    {:stop, {:shutdown, :session_exited}, socket}
  end

  defp dispatch({:session_usage, _session_id, payload}, socket) do
    push(socket, "usage", payload)
    {:noreply, socket}
  end

  # §8.3's bridge-verification failure (`Arbiter.Sessions.broadcast_error/2`)
  # arrives the same way a live `usage` payload does — see the moduledoc
  # table's `error` row.
  defp dispatch({:session_error, _session_id, payload}, socket) do
    push(socket, "error", payload)
    {:noreply, socket}
  end

  # The reader is told the bytes are on the wire the moment they are handed to
  # the socket; a client that cannot drain them shows up as unacknowledged
  # bytes on the *next* frame, which is where the high-water mark bites.
  defp push_frame(socket, session_id, frame) do
    push(socket, "stdout", {:binary, frame})
    Stream.ack(session_id, byte_size(frame))
  end

  # `last_seq` is a byte offset, so `0` — the very start of the stream — is a
  # legitimate resume point.
  defp non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_integer(_value), do: nil

  # Geometry is not: `Terminal.resize/4` takes `pos_integer()`. xterm.js's fit
  # addon reports `0` cols/rows for a terminal whose container has not been laid
  # out yet (a background tab, a join before first paint), and the reader is
  # shared, so letting a `0` through would take every other attached client's
  # stream down with it. `nil` means "no opinion" — keep the pane's size.
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp error_code({:self_kill, _detail}), do: "self_kill_refused"
  defp error_code(:not_attached), do: "not_attached"
  defp error_code(:session_gone), do: "session_gone"
  defp error_code({:tmux_failed, _status, _out}), do: "bridge_unavailable"
  defp error_code(_reason), do: "error"
end
