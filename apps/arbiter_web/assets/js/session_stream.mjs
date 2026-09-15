// The browser terminal's protocol engine (bd-c76fu9, phase 5 of
// `docs/browser-hosted-coordinator-sessions.md`).
//
// This module speaks phase 4's channel (§5.2/§5.3) and knows nothing about
// xterm, the DOM or LiveView. That split is deliberate and load-bearing: the
// parts of the terminal that are easy to get subtly wrong — the `last_seq`
// rejoin, duplicate suppression after a resume, binary stdin framing, the
// debounced resize — are exactly the parts a browser makes impossible to test.
// Keeping them DOM-free lets `apps/arbiter_web/test/js/session_stream_test.mjs`
// drive them under `node --test`, and lets
// `scripts/verify_session_transport.mjs` drive this same code against a real
// socket and a real reader.
//
// `assets/js/session_terminal.mjs` is the other half: xterm, the canvas
// renderer, the fit addon and the DOM.

export const MAGIC = "ARB1"
export const HEADER_SIZE = 12

// Keystrokes are tiny; a paste is not. 4 KiB keeps a single frame well under
// the socket's 1 MiB `max_frame_size` and under any reasonable PTY write.
const DEFAULT_STDIN_CHUNK_BYTES = 4096
const DEFAULT_RESIZE_DEBOUNCE_MS = 100

const encoder = new TextEncoder()

/**
 * Frame `payload` under `seq` as `Arbiter.Sessions.Frame` does:
 *
 *     <<"ARB1", seq::unsigned-big-64, payload::binary>>
 *
 * The payload is copied verbatim — never decoded, never validated. A PTY read
 * boundary lands wherever the kernel put it, and anything that re-encodes
 * mid-escape-sequence corrupts it permanently.
 */
export function encodeFrame(seq, payload) {
  const frame = new Uint8Array(HEADER_SIZE + payload.length)

  frame[0] = 0x41 // A
  frame[1] = 0x52 // R
  frame[2] = 0x42 // B
  frame[3] = 0x31 // 1
  new DataView(frame.buffer).setBigUint64(4, BigInt(seq))
  frame.set(payload, HEADER_SIZE)

  return frame
}

/** `{seq, payload}` for an ARB1 frame, or `null` for anything else. */
export function decodeFrame(buffer) {
  const view = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)

  if (view.length < HEADER_SIZE) return null
  if (view[0] !== 0x41 || view[1] !== 0x52 || view[2] !== 0x42 || view[3] !== 0x31) return null

  const header = new DataView(view.buffer, view.byteOffset, view.byteLength)

  return { seq: Number(header.getBigUint64(4)), payload: view.subarray(HEADER_SIZE) }
}

/**
 * One attached terminal client.
 *
 * `sink` is the renderer-shaped side of it, all optional:
 *
 *   write(payload, info)   fresh terminal bytes; `info` carries the frame's
 *                          `seq`, and the `skipped`/`gap` byte counts
 *   repaint(seq, data, info)  a snapshot: clear and redraw from `data`
 *   meta(meta) / exit(payload) / error(err)
 *   status(state)          "connecting" | "live" | "reconnecting" |
 *                          "detached" | "ended"
 */
export class SessionStream {
  constructor({
    socket,
    sessionId,
    geometry,
    sink = {},
    stdinChunkBytes = DEFAULT_STDIN_CHUNK_BYTES,
    resizeDebounceMs = DEFAULT_RESIZE_DEBOUNCE_MS
  }) {
    this.socket = socket
    this.sessionId = sessionId
    this.geometry = geometry || (() => ({}))
    this.sink = sink
    this.stdinChunkBytes = stdinChunkBytes
    this.resizeDebounceMs = resizeDebounceMs

    this.joins = 0
    this.reconnects = 0
    this.snapshots = 0
    this.finished = false

    this._lastSeq = null
    this._status = null
    this._stdinSeq = 0
    this._pendingResize = null
    this._pushedGeometry = null
    this._resizeTimer = null
  }

  /** The stream offset of the last byte rendered — the resume point. */
  get lastSeq() {
    return this._lastSeq
  }

  connect() {
    this._setStatus("connecting")

    this.socket.onError((err) => this._emit("error", { code: "socket_error", detail: err }))
    this.socket.onClose((event) => this._onSocketClose(event))

    // Params as a FUNCTION, not an object. phoenix.js re-evaluates the join
    // payload on every rejoin, so the reconnect after a restart carries the
    // newest `last_seq`. An object literal here would silently resume from
    // wherever the very first connection started — a real trap, and a silent
    // one: the terminal would look fine and repaint the whole session.
    this.channel = this.socket.channel(`session:${this.sessionId}`, () => {
      const { cols, rows } = this.geometry() || {}
      return { last_seq: this._lastSeq, cols, rows }
    })

    this.channel.on("stdout", (payload) => this._onStdout(payload))
    this.channel.on("snapshot", (payload) => this._onSnapshot(payload))
    this.channel.on("meta", (meta) => this._emit("meta", meta))
    this.channel.on("error", (err) => this._emit("error", err))
    this.channel.on("exit", (payload) => this._onExit(payload))

    // Channel errors are the rejoin path, not a failure: the socket is down
    // and phoenix.js will re-run the params closure when it comes back.
    this.channel.onError(() => {
      if (!this.finished) this._setStatus("reconnecting")
    })

    this.channel
      .join()
      .receive("ok", (reply) => {
        this.joins += 1
        if (this.joins > 1) this.reconnects += 1
        this._setStatus("live")
        this._emit("joined", reply)
      })
      .receive("error", (err) => this._emit("error", err))

    this.socket.connect()

    return this
  }

  /** Type `text` into the pane. UTF-8 encoded here; never decoded in transit. */
  send(text) {
    return this.sendBytes(encoder.encode(text))
  }

  /** A paste (§6.3) — same path as typing, just larger, so it is chunked. */
  paste(text) {
    return this.send(text)
  }

  sendBytes(bytes) {
    if (!this.channel || this.finished || bytes.length === 0) return false

    for (let offset = 0; offset < bytes.length; offset += this.stdinChunkBytes) {
      const chunk = bytes.subarray(offset, offset + this.stdinChunkBytes)

      // The client's own monotonic counter, not a stream offset: it is what
      // lets the server drop stdin a reconnecting client re-sends rather than
      // typing the same keystrokes into the pane twice.
      this._stdinSeq += 1
      this.channel.push("stdin", encodeFrame(this._stdinSeq, chunk).buffer)
    }

    return true
  }

  /**
   * Note a new geometry and push it once the operator stops dragging.
   *
   * Debounced because a window drag emits a `ResizeObserver` callback per
   * frame, and every `resize` that reaches the server re-lays-out the pane for
   * *every* attached client, then makes the agent redraw.
   */
  resize(cols, rows) {
    if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) return

    this._pendingResize = { cols, rows }

    if (this._resizeTimer) return

    this._resizeTimer = setTimeout(() => {
      this._resizeTimer = null
      this._flushResize()
    }, this.resizeDebounceMs)
  }

  /** Leave the session running, drop this client's reader. */
  detach() {
    if (this.channel) this.channel.push("detach", {})
    this._finish("detached")
  }

  /** End the session. The channel requires the confirmation explicitly. */
  kill() {
    if (!this.channel) return null
    return this.channel.push("kill", { confirm: true })
  }

  dispose() {
    this._finish(null)
  }

  // -- internals --------------------------------------------------------------

  _onStdout(raw) {
    const frame = decodeFrame(raw)

    if (!frame) {
      this._emit("error", { code: "bad_frame", detail: "stdout was not an ARB1 frame" })
      return
    }

    const { seq, payload } = frame
    const start = seq - payload.length

    let skipped = 0
    let gap = 0

    if (this._lastSeq !== null) {
      if (start > this._lastSeq) {
        // Bytes the pane produced that never reached us. Nothing here can
        // recover them; the renderer is told so it can say so.
        gap = start - this._lastSeq
      } else if (start < this._lastSeq) {
        // Overlap. A resume replays from `last_seq`, and a ring that re-sent a
        // frame boundary would otherwise redraw bytes already on screen — for
        // a terminal that is not cosmetic, it is a second prompt and a second
        // half-line of output.
        skipped = Math.min(this._lastSeq - start, payload.length)
      }
    }

    this._lastSeq = this._lastSeq === null ? seq : Math.max(this._lastSeq, seq)
    this._emit("write", skipped ? payload.subarray(skipped) : payload, {
      seq,
      start,
      skipped,
      gap
    })
  }

  _onSnapshot({ seq, data }) {
    this.snapshots += 1

    // A snapshot restarts the byte stream at `seq`, so the resume arithmetic
    // restarts with it. On a *re*join it also means the ring could not cover
    // the outage: the operator keeps their session, but loses the gap.
    const rejoin = this.joins > 1
    this._lastSeq = seq
    this._emit("repaint", seq, data, { rejoin })
  }

  _onExit(payload) {
    this._emit("exit", payload)
    this._finish("ended")
  }

  _onSocketClose(event) {
    if (this.finished) return

    this._setStatus("reconnecting")

    // phoenix.js deliberately does not reconnect after a 1000 (normal
    // closure), and a graceful `systemctl --user restart arbiter` produces
    // exactly that — Bandit closes every WebSocket with 1000 before the BEAM
    // exits. For a session that outlives the server by design (§4.3) that is
    // the wrong reading: a clean server close means "back shortly", not "stop
    // watching". §10.1 is the whole point of the feature.
    if (event && event.code === 1000) this.socket.reconnectTimer.scheduleTimeout()
  }

  _flushResize() {
    const next = this._pendingResize
    this._pendingResize = null

    if (!next || !this.channel || this.finished) return

    const current = this._pushedGeometry
    if (current && current.cols === next.cols && current.rows === next.rows) return

    this._pushedGeometry = next
    this.channel.push("resize", next)
  }

  _finish(status) {
    if (this.finished) return
    this.finished = true

    if (this._resizeTimer) {
      clearTimeout(this._resizeTimer)
      this._resizeTimer = null
    }

    if (status) this._setStatus(status)
    if (this.socket) this.socket.disconnect()
  }

  // A drop raises both `socket.onClose` and `channel.onError`, and a rejoin
  // can raise `status("live")` more than once. The sink is a UI: it wants
  // transitions, not every notification that produced one.
  _setStatus(status) {
    if (this._status === status) return
    this._status = status
    this._emit("status", status)
  }

  _emit(name, ...args) {
    const handler = this.sink[name]
    if (typeof handler === "function") handler(...args)
  }
}
