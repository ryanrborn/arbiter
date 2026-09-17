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
import { FakeSocket } from "./support/phoenix_fake.mjs"

// The phoenix.js stand-in lives in `support/phoenix_fake.mjs`: more than one
// suite drives this module through it now — `session_geometry_test.mjs` wires
// two clients to one simulated pane through the same fakes.

// A sink that records everything, in order.
function recorder() {
  const log = { writes: [], repaints: [], metas: [], usages: [], exits: [], errors: [], statuses: [] }
  return {
    log,
    text() { return log.writes.map((w) => Buffer.from(w.payload).toString("utf8")).join("") },
    sink: {
      write: (payload, info) => log.writes.push({ payload, info }),
      repaint: (seq, data, info) => log.repaints.push({ seq, data, info }),
      meta: (m) => log.metas.push(m),
      usage: (u) => log.usages.push(u),
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

test("a usage event is forwarded to the sink verbatim (§7.5, phase 7)", () => {
  const { channel, rec } = connected()

  const payload = {
    tokens_in: 100,
    tokens_out: 50,
    cache_creation: 0,
    cache_read: 0,
    cost_usd: 0.42,
    model: "claude-opus-5",
    estimated: true
  }

  channel.emit("usage", payload)
  assert.deepEqual(rec.log.usages, [payload])
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

test("a refused join is tagged so a headless client can stop retrying", () => {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-gone",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink
  })
  stream.connect()

  socket.channel0.joins[0].push.reply("error", {
    code: "session_gone",
    detail: "no live session sess-gone"
  })

  // phoenix.js re-joins forever on its own timer, so a refusal it can never
  // fix has to be distinguishable from a slow reconnect — otherwise
  // `scripts/verify_session_transport.mjs`, the instrument criterion 8 is
  // measured with, spins silently instead of failing.
  assert.equal(rec.log.errors.length, 1)
  assert.equal(rec.log.errors[0].code, "session_gone")
  assert.equal(rec.log.errors[0].join_refused, true)

  // An in-band error event is *not* tagged: those are per-message and the
  // channel is still perfectly usable after one.
  socket.channel0.emit("error", { code: "bad_frame", detail: "stdin was not ARB1" })
  assert.equal(rec.log.errors[1].join_refused, undefined)
})

test("a refusal that could succeed later keeps the client trying", () => {
  // bd-3r2otb: the bridge may not be up the instant the launch redirect lands
  // on the page. A refusal like this one is "ask again", and the client must
  // say so rather than sit on "connecting…" — which is what the operator saw
  // on the first live check, with no way to tell a retrying client from a
  // wedged one.
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink
  })
  stream.connect()

  socket.channel0.joins[0].push.reply("error", {
    code: "bridge_unavailable",
    detail: "{:error, :enoent}"
  })

  assert.equal(stream.finished, false)
  assert.equal(socket.disconnected, false)
  assert.equal(stream.joinRefusals, 1)
  assert.deepEqual(rec.log.statuses, ["connecting", "reconnecting"])

  // phoenix.js re-sends the same join push on its rejoin timer, so the retry
  // arrives on the push we already hold.
  socket.channel0.joins[0].push.reply("ok", { seq: 0, mode: "snapshot" })

  assert.deepEqual(rec.log.statuses, ["connecting", "reconnecting", "live"])
  assert.equal(stream.joins, 1)
})

test("a refusal that can never succeed stops rather than spinning", () => {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-gone",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink
  })
  stream.connect()

  socket.channel0.joins[0].push.reply("error", { code: "session_gone", detail: "no live session" })

  // Left alone, phoenix.js rejoins a dead topic every few seconds for as long
  // as the tab is open.
  assert.equal(stream.finished, true)
  assert.equal(socket.disconnected, true)
  assert.deepEqual(rec.log.statuses, ["connecting", "ended"])
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

// A paste reaches the stream the same way typing does — through xterm's
// `Terminal.paste()` -> `onData` -> `send`, so it has already been newline
// normalized and bracketed by the time it gets here. All the stream adds is
// chunking, because a 200 KB paste must not become one socket frame.
test("a large paste is chunked into several stdin frames (§6.3)", () => {
  const { channel, stream } = connected({ stdinChunkBytes: 16 })

  stream.send("x".repeat(40))

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

// -- the pane's geometry, when more than one client is pushing one (bd-4tjw34)

test("a geometry noted from a meta becomes the size a resize is deduped against", async () => {
  const { stream, channel } = connected()

  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))
  assert.equal(channel.pushesFor("resize").length, 1)

  // Another client resized the pane out from under us. Without this the cache
  // would still read 100x30, and this client reclaiming the pane at its own
  // size would be swallowed as a no-op — leaving the pane at the other
  // client's geometry and the reclaim doing nothing at all.
  stream.noteGeometry(120, 40)

  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  assert.deepEqual(
    channel.pushesFor("resize").map((p) => p.payload),
    [
      { cols: 100, rows: 30 },
      { cols: 100, rows: 30 }
    ]
  )
})

test("a meta reporting the geometry we asked for still suppresses the next resize", async () => {
  const { stream, channel } = connected()

  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  stream.noteGeometry(100, 30)
  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  assert.equal(channel.pushesFor("resize").length, 1)
})

test("an unusable geometry is never noted", async () => {
  const { stream, channel } = connected()

  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  for (const [cols, rows] of [[0, 30], [100, 0], [-1, 30], [null, 30], [100.5, 30]]) {
    stream.noteGeometry(cols, rows)
  }

  stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  assert.equal(channel.pushesFor("resize").length, 1, "the cache was left alone")
})

// -- remount / redraw (bd-14b11h) ---------------------------------------------

test("a remounted stream re-announces its geometry even when the pane already has it", async () => {
  // Navigating away disposes the stream; navigating back builds a new one. The
  // "the pane already has this size" suppression above is *per client*, and a
  // fresh client has pushed nothing — if it stayed quiet because the geometry
  // happens to match what it fitted, the pane would never be told which client
  // is driving it and #1733's disagreement would go unreconciled.
  const first = connected()
  first.stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))
  assert.equal(first.channel.pushesFor("resize").length, 1)
  first.stream.dispose()

  const second = connected()
  second.stream.resize(100, 30)
  await new Promise((resolve) => setTimeout(resolve, 60))

  assert.deepEqual(second.channel.pushesFor("resize").map((p) => p.payload), [
    { cols: 100, rows: 30 }
  ])
})

test("the join reply reaches the sink so a mount can see whether it resized the pane", () => {
  const socket = new FakeSocket()
  const joins = []
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 96, rows: 30 }),
    sink: { ...rec.sink, joined: (reply) => joins.push(reply) }
  })

  stream.connect()
  socket.channel0.joins[0].push.reply("ok", { seq: 12, mode: "snapshot", resized: true })

  assert.deepEqual(joins, [{ seq: 12, mode: "snapshot", resized: true }])
})

test("redraw asks the pane to make the agent repaint", () => {
  const { channel, stream } = connected()

  assert.equal(stream.redraw(), true)
  assert.deepEqual(channel.pushesFor("redraw").map((p) => p.payload), [{}])
})

test("redraw is not pushed into a stream that has finished", () => {
  const { channel, stream } = connected()

  stream.detach()

  assert.equal(stream.redraw(), false)
  assert.equal(channel.pushesFor("redraw").length, 0)
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

// A window whose session ended stays in the dock, read-only, with its final
// scrollback (bd-a292yj, session dock phase 3). The pane surviving is the
// point; the *stream* surviving is not — nothing typed into a dead pane may
// reach the server, and this is the layer that guarantees it regardless of
// what xterm does.

test("stdin typed into a session that has exited never reaches the wire", () => {
  const { channel, stream } = connected()

  channel.emit("exit", { code: 0, reason: "agent exited" })
  const before = channel.pushesFor("stdin").length

  assert.equal(stream.send("rm -rf /\r"), false)
  assert.equal(stream.sendBytes(new Uint8Array([3])), false)
  assert.equal(channel.pushesFor("stdin").length, before)
})

// -- a seeded resume point (bd-9myzv8, session dock phase 2) ------------------
//
// The dock tears the xterm and the socket down on collapse, so the stream
// object that held `last_seq` is gone by the time the operator expands the
// window again. The resume point has to be handed back in, or every expand
// would re-snapshot from wherever the ring happens to start.

test("a seeded lastSeq is the resume point the very first join carries", () => {
  const socket = new FakeSocket()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 100, rows: 30 }),
    lastSeq: 4096
  })

  assert.equal(stream.lastSeq, 4096)

  stream.connect()

  assert.deepEqual(socket.channel0.joins[0].params, { last_seq: 4096, cols: 100, rows: 30 })
})

test("a resumed replay onto a seeded offset drops the bytes already rendered", () => {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink,
    lastSeq: 5
  })
  stream.connect()
  const channel = socket.channel0
  channel.joins[0].push.reply("ok", { seq: 5, mode: "resumed" })

  // The ring re-sent a frame boundary that starts before the seeded offset.
  channel.emit("stdout", serverFrame(11, "hello world".slice(0, 11)))

  assert.equal(rec.text(), " world")
  assert.equal(stream.lastSeq, 11)
})

test("a nonsense lastSeq is ignored rather than put on the wire", () => {
  for (const bad of [null, undefined, -1, 1.5, "12", NaN]) {
    const socket = new FakeSocket()
    const stream = new SessionStream({ socket, sessionId: "s", lastSeq: bad })
    stream.connect()
    assert.equal(stream.lastSeq, null, `lastSeq: ${String(bad)}`)
    assert.equal(socket.channel0.joins[0].params.last_seq, null, `lastSeq: ${String(bad)}`)
  }
})
