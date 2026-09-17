// A phoenix.js stand-in for the browser terminal's `node --test` suites.
//
// Shared rather than copied because more than one suite now needs it:
// `session_stream_test.mjs` drives one client's protocol through it, and
// `session_geometry_test.mjs` wires *two* clients to one simulated pane to
// prove they never fight over its geometry (bd-4tjw34).
//
// `socket.onPush` is the seam that makes the second of those possible: a real
// channel's pushes reach a server, and these have to reach something too.

export class FakePush {
  constructor() { this.handlers = {} }
  receive(status, cb) { (this.handlers[status] ||= []).push(cb); return this }
  reply(status, payload) { (this.handlers[status] || []).forEach((cb) => cb(payload)) }
}

export class FakeChannel {
  constructor(topic, params, socket) {
    this.topic = topic
    this.params = params
    this.socket = socket
    this.events = {}
    this.pushes = []
    this.joins = []
    this.left = false
  }
  on(event, cb) { (this.events[event] ||= []).push(cb) }
  onError(cb) { this.errorHandler = cb }
  onClose(cb) { this.closeHandler = cb }
  join() { const p = new FakePush(); this.joins.push({ params: this.params(), push: p }); return p }
  push(event, payload) {
    const p = new FakePush()
    this.pushes.push({ event, payload, push: p })
    if (this.socket && this.socket.onPush) this.socket.onPush(event, payload)
    return p
  }
  leave() { this.left = true; return new FakePush() }
  emit(event, payload) { (this.events[event] || []).forEach((cb) => cb(payload)) }
  pushesFor(event) { return this.pushes.filter((p) => p.event === event) }
}

export class FakeSocket {
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
  channel(topic, params) { const c = new FakeChannel(topic, params, this); this.channels.push(c); return c }
  get channel0() { return this.channels[0] }
}
