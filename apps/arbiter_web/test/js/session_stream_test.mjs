// The browser terminal's protocol engine, under `node --test` (bd-c76fu9,
// phase 5 acceptance criteria 2 and 3).
//
// `assets/js/session_stream.mjs` is deliberately DOM-free so it can be tested
// here: it owns the parts of §6.3/§5.3 that are easy to get subtly wrong and
// invisible when wrong — the `last_seq` rejoin closure, duplicate suppression
// after a resume, binary stdin framing, and the debounced resize. The xterm
// and DOM wiring lives in `session_terminal.mjs` and is exercised by
// `scripts/verify_session_transport.mjs` against a real socket instead.
//
//   node --test apps/arbiter_web/test/js
//
// No npm: `node:test` and `node:assert` are built in (RFC §6.1).

import test from "node:test"
import assert from "node:assert/strict"

import {
  SessionStream,
  decodeFrame,
  encodeFrame
} from "../../assets/js/session_stream.mjs"

// -- a phoenix.js stand-in ----------------------------------------------------

class FakePush {
  constructor() { this.handlers = {} }
  receive(status, cb) { (this.handlers[status] ||= []).push(cb); return this }
  reply(status, payload) { (this.handlers[status] || []).forEach((cb) => cb(payload)) }
}

class FakeChannel {
  constructor(topic, params) {
    this.topic = topic
    this.params = params
    this.events = {}
    this.pushes = []
    this.joins = []
    this.left = false
  }
  on(event, cb) { (this.events[event] ||= []).push(cb) }
  onError(cb) { this.errorHandler = cb }
  onClose(cb) { this.closeHandler = cb }
  join() { const p = new FakePush(); this.joins.push({ params: this.params(), push: p }); return p }
  push(event, payload) { const p = new FakePush(); this.pushes.push({ event, payload, push: p }); return p }
  leave() { this.left = true; return new FakePush() }
  emit(event, payload) { (this.events[event] || []).forEach((cb) => cb(payload)) }
  pushesFor(event) { return this.pushes.filter((p) => p.event === event) }
}

class FakeSocket {
  constructor() {
    this.channels = []
    this.connected = false
    this.disconnected = false
    this.scheduledReconnects = 0
    this.reconnectTimer = { scheduleTimeout: () => { this.scheduledReconnects++ } }
  }
  onOpen(cb) { this.openHandler = cb }
  onClose(cb) { this.closeHandler = cb }
  onError(cb) { this.errorHandler = cb }
  connect() { this.connected = true }
  disconnect() { this.disconnected = true }
  channel(topic, params) { const c = new FakeChannel(topic, params); this.channels.push(c); return c }
  get channel0() { return this.channels[0] }
}

// A sink that records everything, in order.
function recorder() {
  const log = { writes: [], repaints: [], metas: [], exits: [], errors: [], statuses: [] }
  return {
    log,
    text() { return log.writes.map((w) => Buffer.from(w.payload).toString("utf8")).join("") },
    sink: {
      write: (payload, info) => log.writes.push({ payload, info }),
      repaint: (seq, data, info) => log.repaints.push({ seq, data, info }),
      meta: (m) => log.metas.push(m),
      exit: (p) => log.exits.push(p),
      error: (e) => log.errors.push(e),
      status: (s) => log.statuses.push(s)
    }
  }
}

function connected(opts = {}) {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink,
    resizeDebounceMs: 20,
    ...opts
  })
  stream.connect()
  const channel = socket.channel0
  channel.joins[0].push.reply("ok", { seq: 0, mode: "snapshot" })
  return { socket, channel, stream, rec }
}

// The server's frame: <<"ARB1", seq::unsigned-big-64, payload>> where `seq` is
// the stream offset of the *last* byte in the frame.
function serverFrame(seq, text) {
  return encodeFrame(seq, new TextEncoder().encode(text)).buffer
}

// -- framing ------------------------------------------------------------------

test("encodeFrame writes the ARB1 header and leaves the payload untouched", () => {
  const payload = new Uint8Array([0x80, 0x00, 0x1b, 0xff])
  const frame = encodeFrame(4096, payload)

  assert.equal(Buffer.from(frame.subarray(0, 4)).toString("latin1"), "ARB1")
  assert.equal(Buffer.from(frame).readBigUInt64BE(4), 4096n)
  assert.deepEqual(Array.from(frame.subarray(12)), Array.from(payload))
})

test("decodeFrame round-trips and rejects anything that is not an ARB1 frame", () => {
  const { seq, payload } = decodeFrame(encodeFrame(7, new Uint8Array([1, 2, 3])).buffer)
  assert.equal(seq, 7)
  assert.deepEqual(Array.from(payload), [1, 2, 3])

  assert.equal(decodeFrame(new Uint8Array([1, 2, 3]).buffer), null)
  assert.equal(decodeFrame(new TextEncoder().encode("not a frame at all").buffer), null)
})

// -- stdout -------------------------------------------------------------------

test("stdout frames are written verbatim and advance last_seq", () => {
  const { channel, stream, rec } = connected()

  channel.emit("stdout", serverFrame(5, "hello"))
  channel.emit("stdout", serverFrame(11, " world"))

  assert.equal(rec.text(), "hello world")
  assert.equal(stream.lastSeq, 11)
})

test("a frame that is not ARB1-framed is reported, not rendered", () => {
  const { channel, rec } = connected()

  channel.emit("stdout", new TextEncoder().encode("raw junk").buffer)

  assert.equal(rec.log.writes.length, 0)
  assert.equal(rec.log.errors.length, 1)
  assert.match(rec.log.errors[0].code, /bad_frame/)
})

test("a snapshot repaints and resets the sequence arithmetic", () => {
  const { channel, stream, rec } = connected()

  channel.emit("snapshot", { seq: 900, data: "SCROLLBACK" })
  assert.deepEqual(rec.log.repaints.map((r) => [r.seq, r.data]), [[900, "SCROLLBACK"]])
  assert.equal(stream.lastSeq, 900)

  channel.emit("stdout", serverFrame(905, "after"))
  assert.equal(rec.text(), "after")
  assert.equal(rec.log.writes[0].info.gap, 0)
})

// -- reconnect + resume (acceptance criterion 3) -------------------------------

test("the rejoin carries the newest last_seq, not the one it first joined with", () => {
  const { socket, channel, stream } = connected()

  assert.deepEqual(channel.joins[0].params, { last_seq: null, cols: 80, rows: 24 })

  channel.emit("stdout", serverFrame(120, "output"))

  // phoenix.js re-evaluates the params closure on every rejoin. An object
  // literal here would silently resume from the start of the run.
  assert.deepEqual(channel.params(), { last_seq: 120, cols: 80, rows: 24 })
  assert.equal(stream.lastSeq, 120)
  assert.equal(socket.scheduledReconnects, 0)
})

test("a socket close shows reconnecting, and a rejoin goes back to live", () => {
  const { socket, channel, rec } = connected()
  assert.deepEqual(rec.log.statuses, ["connecting", "live"])

  socket.closeHandler({ code: 1006 })
  assert.equal(rec.log.statuses.at(-1), "reconnecting")

  channel.joins[0].push.reply("ok", { seq: 120, mode: "resumed" })
  assert.equal(rec.log.statuses.at(-1), "live")
})

test("a clean 1000 close still schedules a reconnect", () => {
  // A graceful `systemctl --user restart arbiter` closes every WebSocket with
  // 1000, and phoenix.js does not reconnect after a normal closure. For a
  // session that outlives the server by design (§4.3) that is the wrong
  // reading: it means "back shortly", not "stop watching".
  const { socket, rec } = connected()

  socket.closeHandler({ code: 1000 })

  assert.equal(socket.scheduledReconnects, 1)
  assert.equal(rec.log.statuses.at(-1), "reconnecting")
})

test("replayed bytes at or below last_seq are not rendered twice", () => {
  const { channel, stream, rec } = connected()

  channel.emit("stdout", serverFrame(10, "0123456789"))
  assert.equal(rec.text(), "0123456789")

  // The server replays from `last_seq`, but a resume that overlaps — a ring
  // that re-sent a frame boundary, a duplicate delivery — must not type the
  // same bytes into the pane twice.
  channel.emit("stdout", serverFrame(10, "0123456789"))
  assert.equal(rec.text(), "0123456789", "a wholly duplicate frame must render nothing")
  assert.equal(rec.log.writes.at(-1).info.skipped, 10)

  // A partially overlapping frame renders only its new tail.
  channel.emit("stdout", serverFrame(14, "789abcd"))
  assert.equal(rec.text(), "0123456789abcd")
  assert.equal(rec.log.writes.at(-1).info.skipped, 3)
  assert.equal(stream.lastSeq, 14)
})

test("a gap is reported rather than silently papered over", () => {
  const { channel, rec } = connected()

  channel.emit("stdout", serverFrame(5, "abcde"))
  channel.emit("stdout", serverFrame(20, "xyz"))

  assert.equal(rec.text(), "abcdexyz")
  assert.equal(rec.log.writes.at(-1).info.gap, 12)
})

// -- stdin --------------------------------------------------------------------

test("stdin is pushed as an ARB1-framed ArrayBuffer with a monotonic counter", () => {
  const { channel, stream } = connected()

  stream.send("ls\r")
  stream.send("é")

  const pushes = channel.pushesFor("stdin")
  assert.equal(pushes.length, 2)

  for (const p of pushes) {
    assert.equal(p.payload.constructor, ArrayBuffer, "phoenix.js only treats ArrayBuffer as binary")
  }

  const first = decodeFrame(pushes[0].payload)
  const second = decodeFrame(pushes[1].payload)

  assert.equal(first.seq, 1)
  assert.equal(second.seq, 2)
  assert.equal(Buffer.from(first.payload).toString("utf8"), "ls\r")
  // Multi-byte input is UTF-8 encoded in the client, never decoded in transit.
  assert.deepEqual(Array.from(second.payload), [0xc3, 0xa9])
})

test("a large paste is chunked into several stdin frames (§6.3)", () => {
  const { channel, stream } = connected({ stdinChunkBytes: 16 })

  stream.paste("x".repeat(40))

  const pushes = channel.pushesFor("stdin")
  assert.equal(pushes.length, 3)
  assert.deepEqual(pushes.map((p) => decodeFrame(p.payload).payload.length), [16, 16, 8])
  assert.deepEqual(pushes.map((p) => decodeFrame(p.payload).seq), [1, 2, 3])
})

// -- resize -------------------------------------------------------------------

test("resize is debounced to a single push carrying the latest geometry", async () => {
  const { channel, stream } = connected()

  stream.resize(80, 24)
  stream.resize(100, 30)
  stream.resize(132, 43)

  assert.equal(channel.pushesFor("resize").length, 0, "nothing goes out inside the debounce window")

  await new Promise((resolve) => setTimeout(resolve, 60))

  const pushes = channel.pushesFor("resize")
  assert.equal(pushes.length, 1)
  assert.deepEqual(pushes[0].payload, { cols: 132, rows: 43 })
})

test("a resize that does not change the geometry is not pushed at all", async () => {
  const { channel, stream } = connected()

  stream.resize(80, 24)
  await new Promise((resolve) => setTimeout(resolve, 60))
  assert.equal(channel.pushesFor("resize").length, 1)

  stream.resize(80, 24)
  await new Promise((resolve) => setTimeout(resolve, 60))
  assert.equal(channel.pushesFor("resize").length, 1, "the pane already has this size")
})

// -- detach / kill / exit ------------------------------------------------------

test("detach leaves the session running and stops the client reconnecting", () => {
  const { socket, channel, stream } = connected()

  stream.detach()

  assert.equal(channel.pushesFor("detach").length, 1)
  assert.equal(socket.disconnected, true)
})

test("kill always carries an explicit confirmation", () => {
  const { channel, stream } = connected()

  stream.kill()

  assert.deepEqual(channel.pushesFor("kill")[0].payload, { confirm: true })
})

test("an exit event ends the stream rather than reconnecting into a dead session", () => {
  const { socket, channel, rec } = connected()

  channel.emit("exit", { code: 0, reason: "agent exited" })

  assert.deepEqual(rec.log.exits, [{ code: 0, reason: "agent exited" }])
  assert.equal(rec.log.statuses.at(-1), "ended")

  socket.closeHandler({ code: 1000 })
  assert.equal(socket.scheduledReconnects, 0, "a finished session must not be rejoined")
})
