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

  ## Client → server

  | Event | Payload | Notes |
  |---|---|---|
  | `join` | `%{last_seq \\| nil, cols, rows}` | session id comes from the topic |
  | `stdin` | `{:binary, frame}` | `Arbiter.Sessions.Frame`; raw bytes |
  | `resize` | `%{cols, rows}` | debounced client-side |
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

  require Logger

  @impl true
  def join("session:" <> session_id, params, socket) do
    with {:ok, session} <- fetch_live_session(session_id),
         {:ok, attached} <- attach(session, params) do
      socket =
        socket
        |> assign(:session_id, session_id)
        |> assign(:attached, attached)
        |> assign(:last_stdin_seq, 0)

      send(self(), :after_join)

      {:ok, %{seq: attached.seq, mode: Atom.to_string(attached.mode)}, socket}
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

    {:noreply, assign(socket, :attached, %{attached | replay: [], snapshot: nil})}
  end

  def handle_info({:session_stdout, session_id, frame}, socket) do
    push_frame(socket, session_id, frame)
    {:noreply, socket}
  end

  def handle_info({:session_snapshot, _session_id, payload}, socket) do
    push(socket, "snapshot", payload)
    {:noreply, socket}
  end

  def handle_info({:session_meta, _session_id, meta}, socket) do
    push(socket, "meta", meta)
    {:noreply, socket}
  end

  def handle_info({:session_exit, _session_id, payload}, socket) do
    push(socket, "exit", payload)
    {:stop, {:shutdown, :session_exited}, socket}
  end

  def handle_info({:session_usage, _session_id, payload}, socket) do
    push(socket, "usage", payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
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
      last_seq: positive_integer(params["last_seq"]),
      cols: positive_integer(params["cols"]),
      rows: positive_integer(params["rows"])
    )
  end

  # The reader is told the bytes are on the wire the moment they are handed to
  # the socket; a client that cannot drain them shows up as unacknowledged
  # bytes on the *next* frame, which is where the high-water mark bites.
  defp push_frame(socket, session_id, frame) do
    push(socket, "stdout", {:binary, frame})
    Stream.ack(session_id, byte_size(frame))
  end

  defp positive_integer(value) when is_integer(value) and value >= 0, do: value
  defp positive_integer(_value), do: nil

  defp error_code({:self_kill, _detail}), do: "self_kill_refused"
  defp error_code(:not_attached), do: "not_attached"
  defp error_code(:session_gone), do: "session_gone"
  defp error_code({:tmux_failed, _status, _out}), do: "bridge_unavailable"
  defp error_code(_reason), do: "error"
end
