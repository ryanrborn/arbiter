// Transcript mode of the browser terminal's protocol engine (bd-3tf4oo,
// #1818), under `node --test`.
//
// A dock window for a session that has *ended* joins the same
// `session:<id>` topic with `mode: "transcript"` and is handed the persisted
// raw capture as one `snapshot`. What has to hold, and is invisible when it
// does not: it paints through the same repaint path a live snapshot uses, it
// puts nothing on the wire afterwards, it never reports itself as live, and
// it does not sit rejoining a session that will never come back.
//
//   node --test apps/arbiter_web/test/js/session_transcript_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { SessionStream } from "../../assets/js/session_stream.mjs"
import { FakeSocket } from "./support/phoenix_fake.mjs"

function recorder() {
  const log = { writes: [], repaints: [], errors: [], statuses: [], joined: [] }
  return {
    log,
    sink: {
      write: (payload, info) => log.writes.push({ payload, info }),
      repaint: (seq, data, info) => log.repaints.push({ seq, data, info }),
      error: (e) => log.errors.push(e),
      status: (s) => log.statuses.push(s),
      joined: (reply) => log.joined.push(reply)
    }
  }
}

const REPLY = {
  mode: "transcript",
  seq: 4096,
  start_offset: 0,
  end_offset: 4096,
  total_bytes: 4096,
  replay_bytes: 4096,
  truncated: false
}

function replaying({ reply = REPLY, refusal = null } = {}) {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    mode: "transcript",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink
  })
  stream.connect()

  const channel = socket.channel0
  if (refusal) channel.joins[0].push.reply("error", refusal)
  else channel.joins[0].push.reply("ok", reply)

  return { socket, channel, stream, rec }
}

test("a transcript join asks for transcript mode", () => {
  const { channel } = replaying()

  assert.equal(channel.joins[0].params.mode, "transcript")
})

test("the transcript is painted through the same repaint path a snapshot uses", () => {
  const { channel, rec } = replaying()

  channel.emit("snapshot", { seq: 4096, data: "[32mhello[0m" })

  assert.equal(rec.log.repaints.length, 1)
  assert.equal(rec.log.repaints[0].data, "[32mhello[0m")
  assert.equal(rec.log.repaints[0].seq, 4096)
})

test("it never reports itself as live", () => {
  const { channel, rec } = replaying()

  channel.emit("snapshot", { seq: 10, data: "done" })

  assert.equal(rec.log.statuses.includes("live"), false)
  assert.equal(rec.log.statuses.at(-1), "transcript")
})

test("it hangs up once the transcript is on screen, so nothing reconnects", () => {
  const { socket, channel, stream } = replaying()

  assert.equal(socket.disconnected, false)
  channel.emit("snapshot", { seq: 10, data: "done" })

  assert.equal(stream.finished, true)
  assert.equal(socket.disconnected, true)
})

test("a closed socket after the replay schedules no reconnect", () => {
  const { socket, channel, rec } = replaying()

  channel.emit("snapshot", { seq: 10, data: "done" })
  socket.closeHandler({ code: 1000 })

  assert.equal(socket.scheduledReconnects, 0)
  assert.equal(rec.log.statuses.includes("reconnecting"), false)
})

test("it puts no stdin on the wire, before or after the replay", () => {
  const { channel, stream } = replaying()

  assert.equal(stream.send("rm -rf /\n"), false)
  channel.emit("snapshot", { seq: 10, data: "done" })
  assert.equal(stream.send("rm -rf /\n"), false)

  assert.equal(channel.pushesFor("stdin").length, 0)
})

test("it pushes no resize at a pane that is gone", () => {
  const { channel, stream } = replaying()

  stream.resize(120, 40)

  assert.equal(channel.pushesFor("resize").length, 0)
})

test("it asks for no redraw", () => {
  const { channel, stream } = replaying()

  assert.equal(stream.redraw(), false)
  assert.equal(channel.pushesFor("redraw").length, 0)
})

test("an unavailable transcript is a permanent refusal, not a retry loop", () => {
  const { socket, rec, stream } = replaying({
    refusal: { code: "transcript_unavailable", reason: "retention_deleted" }
  })

  assert.equal(rec.log.errors.length, 1)
  assert.equal(rec.log.errors[0].code, "transcript_unavailable")
  assert.equal(rec.log.errors[0].reason, "retention_deleted")
  assert.equal(rec.log.errors[0].join_refused, true)
  assert.equal(stream.finished, true)
  assert.equal(socket.disconnected, true)
  assert.equal(rec.log.statuses.includes("reconnecting"), false)
})

test("a live stream is unaffected: it joins without a mode and stays connected", () => {
  const socket = new FakeSocket()
  const rec = recorder()
  const stream = new SessionStream({
    socket,
    sessionId: "sess-1",
    geometry: () => ({ cols: 80, rows: 24 }),
    sink: rec.sink
  })
  stream.connect()

  const channel = socket.channel0
  channel.joins[0].push.reply("ok", { seq: 0, mode: "snapshot" })
  channel.emit("snapshot", { seq: 0, data: "SNAP" })

  assert.equal(channel.joins[0].params.mode, undefined)
  assert.equal(stream.finished, false)
  assert.equal(socket.disconnected, false)
  assert.equal(rec.log.statuses.at(-1), "live")
})
