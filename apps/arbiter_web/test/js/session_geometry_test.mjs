// Cross-client pane geometry, under `node --test` (bd-4tjw34).
//
// A session's real geometry is its single tmux pane, and every attached
// browser client pushes its own fitted cols/rows to it — last writer wins. So
// two clients of different sizes disagree by construction, and the policy that
// settles the disagreement has to do two things that pull against each other:
// the client that did *not* cause the change has to end up rendering at the
// pane's geometry (or it stays garbled), and it must not answer by pushing its
// own back (or two idle tabs resize each other forever).
//
// `assets/js/session_geometry.mjs` is that policy, kept DOM-free for the same
// reason `session_stream.mjs` is: the failure mode here is a *loop*, and a
// loop is exactly what a browser makes impossible to assert on.
//
//   node --test apps/arbiter_web/test/js/session_geometry_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { PaneGeometry } from "../../assets/js/session_geometry.mjs"
import { SessionStream } from "../../assets/js/session_stream.mjs"
import { FakeSocket } from "./support/phoenix_fake.mjs"

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// -- the policy on its own ----------------------------------------------------

test("a first fit is applied locally and announced to the pane", () => {
  const geometry = new PaneGeometry()

  assert.deepEqual(geometry.fit({ cols: 100, rows: 30 }), {
    apply: { cols: 100, rows: 30 },
    announce: { cols: 100, rows: 30 }
  })
  assert.equal(geometry.adopted, false)
})

test("a measurement that did not change is neither applied nor announced", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  assert.deepEqual(geometry.fit({ cols: 100, rows: 30 }), { apply: null, announce: null })
})

test("an unmeasurable pane changes nothing", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  assert.deepEqual(geometry.fit(null), { apply: null, announce: null })
  assert.deepEqual(geometry.own, { cols: 100, rows: 30 })
})

test("another client's geometry is adopted: applied locally, never announced", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  const outcome = geometry.note({ cols: 120, rows: 40, attached_clients: 2 })

  assert.deepEqual(outcome, { apply: { cols: 120, rows: 40 } })
  assert.equal(geometry.adopted, true, "the pane is not at this client's own size")
  assert.deepEqual(geometry.own, { cols: 100, rows: 30 }, "our own fit is remembered")
})

test("the meta for a change this client made is not an adoption", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  assert.deepEqual(geometry.note({ cols: 100, rows: 30 }), { apply: null })
  assert.equal(geometry.adopted, false)
})

test("a repeated meta for an already adopted geometry does nothing", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })
  geometry.note({ cols: 120, rows: 40 })

  assert.deepEqual(geometry.note({ cols: 120, rows: 40 }), { apply: null })
  assert.equal(geometry.adopted, true)
})

test("a layout change that does not move this client's fit never reclaims the pane", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })
  geometry.note({ cols: 120, rows: 40 })

  // The `ResizeObserver` firing for something that did not move the box — the
  // adopted resize itself is one — must not push our own geometry back.
  assert.deepEqual(geometry.fit({ cols: 100, rows: 30 }), { apply: null, announce: null })
  assert.equal(geometry.adopted, true, "still showing the pane's geometry")
})

test("interacting reclaims the pane at this client's own geometry", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })
  geometry.note({ cols: 120, rows: 40 })

  assert.deepEqual(geometry.fit({ cols: 100, rows: 30 }, { force: true }), {
    apply: { cols: 100, rows: 30 },
    announce: { cols: 100, rows: 30 }
  })
  assert.equal(geometry.adopted, false)
})

test("a container that really did change reclaims the pane without being forced", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  assert.deepEqual(geometry.fit({ cols: 90, rows: 24 }), {
    apply: { cols: 90, rows: 24 },
    announce: { cols: 90, rows: 24 }
  })
  assert.equal(geometry.adopted, false)
})

test("an adopted client's own box moving is remembered, never announced", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })
  geometry.note({ cols: 120, rows: 40 })

  // Adopting a geometry larger than the container is what puts a scrollbar on
  // it, and the scrollbar takes a row back. Answering that with a push is a
  // resize fight with a client that has done nothing (found in a real browser
  // by `scripts/verify_session_dock_terminal.mjs`).
  assert.deepEqual(geometry.fit({ cols: 100, rows: 29 }), { apply: null, announce: null })
  assert.equal(geometry.adopted, true)

  // ...but it *is* what the next reclaim asks for.
  assert.deepEqual(geometry.fit({ cols: 100, rows: 29 }, { force: true }), {
    apply: { cols: 100, rows: 29 },
    announce: { cols: 100, rows: 29 }
  })
})

test("a pane that answers with a geometry we did not ask for is adopted", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  // The server clamped, or another client won the race in between.
  assert.deepEqual(geometry.note({ cols: 80, rows: 24 }), { apply: { cols: 80, rows: 24 } })
  assert.equal(geometry.adopted, true)
})

test("a meta without a usable geometry is ignored", () => {
  const geometry = new PaneGeometry()
  geometry.fit({ cols: 100, rows: 30 })

  for (const meta of [null, {}, { cols: 0, rows: 40 }, { cols: 120, rows: -1 }, { error: "x" }]) {
    assert.deepEqual(geometry.note(meta), { apply: null }, JSON.stringify(meta))
  }

  assert.equal(geometry.adopted, false)
})

// -- the hook/stream seam: two clients, one pane ------------------------------
//
// The pane is the real thing's contract in miniature: last writer wins, and
// every attached client — including the one that asked — is told the result.

class FakePane {
  constructor() {
    this.clients = []
    this.cols = null
    this.rows = null
    this.resizes = []
  }

  attach(client) {
    this.clients.push(client)
    return this
  }

  resize(cols, rows) {
    this.resizes.push({ cols, rows })
    if (this.cols === cols && this.rows === rows) return
    this.cols = cols
    this.rows = rows
    this.broadcast()
  }

  broadcast() {
    const meta = { cols: this.cols, rows: this.rows, attached_clients: this.clients.length }
    for (const client of this.clients) client.deliverMeta(meta)
  }
}

// One browser client, wired exactly the way `session_terminal.mjs` wires one:
// a `SessionStream` for the protocol, a `PaneGeometry` for the policy, and a
// stand-in terminal that records the geometry it was resized to.
class FakeClient {
  constructor(pane, own) {
    this.pane = pane
    this.own = own
    this.geometry = new PaneGeometry()
    this.term = { cols: 80, rows: 24 }
    this.label = null

    this.socket = new FakeSocket()
    this.socket.onPush = (event, payload) => {
      if (event === "resize") this.pane.resize(payload.cols, payload.rows)
    }

    this.stream = new SessionStream({
      socket: this.socket,
      sessionId: "session",
      geometry: () => ({ cols: this.term.cols, rows: this.term.rows }),
      resizeDebounceMs: 1,
      sink: { meta: (meta) => this.onMeta(meta) }
    })

    pane.attach(this)
  }

  /** Mount: measure, apply, connect, announce. */
  mount() {
    const { apply } = this.geometry.fit(this.own, { force: true })
    this.applyGeometry(apply)
    this.stream.connect()
    this.socket.channel0.joins[0].push.reply("ok", { seq: 0, mode: "snapshot", resized: false })
    this.stream.resize(this.own.cols, this.own.rows)
    return this
  }

  /** The single refit path. `force` is "the operator interacted with me". */
  refit(options = {}) {
    const { apply, announce } = this.geometry.fit(this.own, options)
    this.applyGeometry(apply)
    if (announce) this.stream.resize(announce.cols, announce.rows)
  }

  deliverMeta(meta) {
    this.socket.channel0.emit("meta", meta)
  }

  onMeta(meta) {
    this.stream.noteGeometry(meta.cols, meta.rows)
    const { apply } = this.geometry.note(meta)
    this.applyGeometry(apply)
    this.label = `${this.geometry.adopted ? "adopted " : ""}${meta.cols}x${meta.rows}`
  }

  applyGeometry(geometry) {
    if (geometry) this.term = { cols: geometry.cols, rows: geometry.rows }
  }

  get resizePushes() {
    return this.socket.channel0.pushesFor("resize").map((p) => p.payload)
  }
}

test("a client adopts the geometry another client gave the pane", async () => {
  const pane = new FakePane()
  const small = new FakeClient(pane, { cols: 100, rows: 30 }).mount()
  await sleep(10)
  const large = new FakeClient(pane, { cols: 120, rows: 40 }).mount()
  await sleep(10)

  assert.deepEqual(small.term, { cols: 120, rows: 40 }, "the small client renders at the pane's size")
  assert.deepEqual(large.term, { cols: 120, rows: 40 })
  assert.equal(small.label, "adopted 120x40", "and says so")
  assert.equal(large.label, "120x40")
})

test("two idle clients of different sizes exchange one resize each and stop", async () => {
  const pane = new FakePane()
  const small = new FakeClient(pane, { cols: 100, rows: 30 }).mount()
  await sleep(10)
  const large = new FakeClient(pane, { cols: 120, rows: 40 }).mount()

  // Long enough for any number of rounds of a fight to have happened.
  await sleep(60)

  assert.deepEqual(small.resizePushes, [{ cols: 100, rows: 30 }])
  assert.deepEqual(large.resizePushes, [{ cols: 120, rows: 40 }])
  assert.equal(pane.resizes.length, 2, "the pane was told twice, once per client")
})

test("a meta never makes a client push its own geometry back", async () => {
  const pane = new FakePane()
  const client = new FakeClient(pane, { cols: 100, rows: 30 }).mount()
  await sleep(10)

  client.deliverMeta({ cols: 132, rows: 43, attached_clients: 2 })
  await sleep(20)

  assert.deepEqual(client.resizePushes, [{ cols: 100, rows: 30 }], "no answer to the meta")
  assert.deepEqual(client.term, { cols: 132, rows: 43 })
})

test("an adopted client whose own box moves still never pushes", async () => {
  const pane = new FakePane()
  const small = new FakeClient(pane, { cols: 100, rows: 30 }).mount()
  await sleep(10)
  const large = new FakeClient(pane, { cols: 120, rows: 40 }).mount()
  await sleep(20)

  // The scrollbar the adopted geometry put on the container.
  small.own = { cols: 100, rows: 29 }
  small.refit()
  await sleep(20)

  assert.deepEqual(small.resizePushes, [{ cols: 100, rows: 30 }], "still exactly one")
  assert.deepEqual(small.term, { cols: 120, rows: 40 }, "and still rendering the pane's geometry")
  assert.deepEqual(large.resizePushes, [{ cols: 120, rows: 40 }])
})

test("interacting with an adopted client reclaims the pane, and the other adopts", async () => {
  const pane = new FakePane()
  const small = new FakeClient(pane, { cols: 100, rows: 30 }).mount()
  await sleep(10)
  const large = new FakeClient(pane, { cols: 120, rows: 40 }).mount()
  await sleep(20)

  assert.equal(small.geometry.adopted, true)

  // A keystroke in the small client.
  small.refit({ force: true })
  await sleep(20)

  assert.deepEqual({ cols: pane.cols, rows: pane.rows }, { cols: 100, rows: 30 })
  assert.deepEqual(small.term, { cols: 100, rows: 30 })
  assert.equal(small.label, "100x30")
  assert.deepEqual(large.term, { cols: 100, rows: 30 }, "the other client follows the pane")
  assert.equal(large.label, "adopted 100x30")

  // ...and nobody answered the reclaim with a resize of their own.
  assert.deepEqual(large.resizePushes, [{ cols: 120, rows: 40 }])
  assert.deepEqual(small.resizePushes, [
    { cols: 100, rows: 30 },
    { cols: 100, rows: 30 }
  ])
})
