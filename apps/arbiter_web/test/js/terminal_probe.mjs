// The browser half of `scripts/verify_session_terminal.mjs` (bd-c76fu9,
// phase 5 acceptance criteria 2, 5 and 6).
//
// Bundled by esbuild and run inside a real headless Chromium, because the
// claims this file checks cannot be made anywhere else: that xterm and the
// **canvas** addon actually construct together at the versions we vendored,
// that a `Uint8Array` write renders (and that a UTF-8 character split across
// two writes is reassembled rather than corrupted), that `FitAddon` computes
// a geometry, and that §6.3's copy/paste bindings do what they claim - a
// multi-line paste normalized to CR and bracketed when the app asks for it,
// sent exactly once - while leaving plain `Ctrl+C` alone.
//
// It drives the *real* `createSessionTerminal`, not a reimplementation. The
// socket endpoint is deliberately unreachable: nothing here needs a server,
// and the checks are about the renderer and the keyboard.

import { createSessionTerminal } from "../../assets/js/session_terminal.mjs"
import { decodeFrame, encodeFrame } from "../../assets/js/session_stream.mjs"

const checks = []

function check(name, detail, ok) {
  checks.push({ name, ok: !!ok, detail })
}

const writeAsync = (term, data) => new Promise((resolve) => term.write(data, resolve))
const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

function lineText(term, row) {
  const line = term.buffer.active.getLine(row)
  return line ? line.translateToString(true) : null
}

function keydown(term, key, { ctrl = false, shift = false } = {}) {
  const target = term.element.querySelector(".xterm-helper-textarea") || term.element
  target.dispatchEvent(
    new KeyboardEvent("keydown", {
      key,
      code: `Key${key.toUpperCase()}`,
      keyCode: key.toUpperCase().charCodeAt(0),
      ctrlKey: ctrl,
      shiftKey: shift,
      bubbles: true,
      cancelable: true
    })
  )
}

export async function probe(el) {
  // A deterministic clipboard: the point is to check *our* handler, not to
  // negotiate a permission prompt in a headless browser.
  // Multi-line on purpose: a single-line paste passes whether or not the
  // handler goes through xterm, and going around xterm is the bug this check
  // exists to catch (no LF -> CR, no bracketed paste).
  const CLIPBOARD = "pasted-from-the-clipboard\nsecond line\r\nthird line\n"

  let copied = null
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: {
      writeText: async (text) => {
        copied = text
      },
      readText: async () => CLIPBOARD
    }
  })

  el.style.width = "800px"
  el.style.height = "400px"

  let handle = null
  let constructError = null

  try {
    handle = createSessionTerminal(el, {
      sessionId: "probe",
      // Unreachable on purpose - no server is involved in these checks.
      endpoint: "ws://127.0.0.1:1/session"
    })
  } catch (error) {
    constructError = String((error && error.stack) || error)
  }

  check("construct", constructError || "createSessionTerminal returned a handle", !constructError)
  if (!handle) return { checks }

  const term = handle.term

  // -- §6.2: the canvas renderer is the one that is actually running ---------
  const canvases = el.querySelectorAll("canvas").length
  check(
    "canvas-renderer",
    `renderer=${handle.renderer} canvas layers=${canvases}`,
    handle.renderer === "canvas" && canvases > 0
  )

  // The DOM renderer would have populated .xterm-rows with per-row divs.
  const domRows = el.querySelectorAll(".xterm-rows > div").length
  check("no-dom-renderer-rows", `.xterm-rows children=${domRows}`, domRows === 0)

  // -- the binary path -------------------------------------------------------
  const bytes = new TextEncoder().encode("hello [31mred[0m")
  await writeAsync(term, bytes)
  const rendered = lineText(term, 0)
  check("binary-write", `row 0 = ${JSON.stringify(rendered)}`, rendered === "hello red")

  const rocket = new TextEncoder().encode("\r\n\u{1F680}ok")
  await writeAsync(term, rocket.subarray(0, 4)) // splits the 4-byte rocket
  await writeAsync(term, rocket.subarray(4))
  const line1 = lineText(term, 1)
  check(
    "split-utf8-reassembled",
    `row 1 = ${JSON.stringify(line1)}`,
    line1 !== null && line1.indexOf("\u{1F680}ok") === 0
  )

  check("scrollback", `scrollback=${term.options.scrollback}`, term.options.scrollback === 5000)

  // -- §6.3: fit ------------------------------------------------------------
  const proposed = handle.fit()
  check(
    "fit-proposes-a-geometry",
    proposed ? `${proposed.cols}x${proposed.rows} (term ${term.cols}x${term.rows})` : "no proposal",
    proposed && proposed.cols > 0 && proposed.rows > 0
  )

  // bd-3r2otb: the pane the dashboard renders has `p-2`, and the old fit addon
  // measured a box that included it — one row too many, and the bottom line of
  // the agent's UI clipped in half. Padding is the regression, so the probe
  // fits a padded element and checks the rendered screen against the *content*
  // box.
  el.style.padding = "8px"
  el.style.height = "417px"
  handle.fit()
  await tick()

  const paneStyle = getComputedStyle(el)
  const contentHeight =
    el.clientHeight - parseFloat(paneStyle.paddingTop) - parseFloat(paneStyle.paddingBottom)
  const screenHeight = el.querySelector(".xterm-screen").getBoundingClientRect().height

  check(
    "fit-stays-inside-a-padded-container",
    `${term.rows} rows render ${screenHeight}px inside a ${contentHeight}px content box`,
    screenHeight <= contentHeight + 0.5
  )

  el.style.padding = "0px"
  el.style.height = "400px"

  // A terminal cannot reflow below ~80 columns, so the pane keeps a floor
  // width and its container scrolls instead (see SessionLive's
  // #terminal-scroller). At the page's `min-w-[640px]` floor the fit must
  // still land at or above 80 columns.
  el.style.width = "640px"
  handle.fit()
  check("narrow-floor-is-at-least-80-cols", `cols=${term.cols} at 640px`, term.cols >= 80)
  el.style.width = "800px"
  handle.fit()

  // -- §6.3: copy / paste ---------------------------------------------------
  const pushes = []
  handle.stream.channel.push = (event, payload) => {
    pushes.push({ event, payload })
    return { receive: () => ({ receive: () => {} }) }
  }

  term.selectAll()
  const selection = term.getSelection()
  check("selection", `selected ${selection.length} chars`, selection.indexOf("hello red") >= 0)

  keydown(term, "C", { ctrl: true, shift: true })
  await tick()
  check(
    "ctrl-shift-c-copies-the-selection",
    `clipboard = ${JSON.stringify((copied || "").slice(0, 20))}`,
    typeof copied === "string" && copied.indexOf("hello red") >= 0
  )
  term.clearSelection()

  pushes.length = 0
  keydown(term, "V", { ctrl: true, shift: true })
  await tick()
  await tick()
  const stdin = pushes.filter((p) => p.event === "stdin")
  const pasted = stdin
    .map((p) => new TextDecoder().decode(decodeFrame(p.payload).payload))
    .join("")

  // Every newline must have arrived as CR: a raw-mode TUI (Claude Code, on the
  // other end of this terminal) reads CR as Enter and does nothing at all with
  // LF, so a paste that keeps its LFs is a paste that silently does not work.
  check(
    "ctrl-shift-v-pastes-as-stdin",
    `stdin = ${JSON.stringify(pasted)}`,
    pasted === "pasted-from-the-clipboard\rsecond line\rthird line\r"
  )

  // Chrome and Firefox bind Ctrl+Shift+V themselves and fire a real paste
  // event at the helper textarea as well. Synthetic key events are untrusted
  // so this probe cannot reproduce that directly - but if the handler ever
  // stopped calling preventDefault() *and* kept its own clipboard read, the
  // duplicate would show up here as a second frame.
  check("paste-is-sent-once", `stdin frames = ${stdin.length}`, stdin.length === 1)

  // Bracketed paste: with the mode off (no app has enabled it here) xterm
  // must send the text bare. With it on it wraps the text in ESC[200~/ESC[201~
  // so the app inserts it as one block instead of running each line.
  pushes.length = 0
  await writeAsync(term, new TextEncoder().encode("\u001b[?2004h"))
  keydown(term, "V", { ctrl: true, shift: true })
  await tick()
  await tick()
  const bracketed = pushes
    .filter((p) => p.event === "stdin")
    .map((p) => new TextDecoder().decode(decodeFrame(p.payload).payload))
    .join("")
  check(
    "bracketed-paste-is-wrapped-when-the-app-asks",
    `stdin = ${JSON.stringify(bracketed.slice(0, 24))}…${JSON.stringify(bracketed.slice(-8))}`,
    bracketed.startsWith("\u001b[200~") && bracketed.endsWith("\u001b[201~")
  )
  await writeAsync(term, new TextEncoder().encode("\u001b[?2004l"))

  // The papercut this binding exists to avoid: plain Ctrl+C must still be
  // SIGINT, not "copy".
  pushes.length = 0
  term.focus()
  keydown(term, "c", { ctrl: true })
  await tick()
  const sigint = pushes
    .filter((p) => p.event === "stdin")
    .map((p) => Array.from(decodeFrame(p.payload).payload))
    .flat()
  check("plain-ctrl-c-is-still-sigint", `stdin bytes = ${JSON.stringify(sigint)}`, sigint[0] === 3)

  // -- the theme follows the dashboard toggle -------------------------------
  // The canvas renderer resolves its palette once, so unlike the pane's CSS
  // background it does not follow `--arb-term-*` on its own. Without the
  // hook's observer, flipping the theme leaves a light terminal in a dark
  // frame until reload.
  const lightBg = term.options.theme.background
  document.documentElement.setAttribute("data-theme", "dark")
  await tick()
  const darkBg = term.options.theme.background
  check(
    "theme-follows-the-dashboard-toggle",
    `${lightBg} -> ${darkBg}`,
    lightBg === "#ffffff" && darkBg === "#16181d"
  )
  document.documentElement.removeAttribute("data-theme")

  // -- framing, in a browser's DataView/BigInt ------------------------------
  const round = decodeFrame(encodeFrame(2 ** 33, new Uint8Array([0xff, 0x00, 0x1b])).buffer)
  check(
    "frame-round-trip",
    round ? `seq=${round.seq} bytes=${Array.from(round.payload)}` : "decode failed",
    round && round.seq === 2 ** 33 && round.payload[0] === 0xff && round.payload[2] === 0x1b
  )

  handle.dispose()

  try {
    await remountChecks()
  } catch (error) {
    check("remount-probe", String((error && error.stack) || error), false)
  }

  try {
    await adoptionChecks()
  } catch (error) {
    check("adoption-probe", String((error && error.stack) || error), false)
  }

  try {
    await dockChecks()
  } catch (error) {
    check("dock-probe", String((error && error.stack) || error), false)
  }

  return { checks }
}

// -- bd-14b11h: the LiveView navigation remount -------------------------------
//
// Navigate away from /sessions/<id> and back and LiveView tears the hook down
// and mounts a fresh one — inside the DOM patch, before the browser has laid
// the new page out. The mount-time fit was a single synchronous measurement:
// a pane with no box yet measured `null`, the fit gave up, and xterm stayed on
// the 80x24 it constructs with. That default is what the join's `cols`/`rows`
// then carried, so the remount resized the pane every client shares and the
// snapshot captured in the same call was reflowed for a geometry the agent had
// not redrawn at. That is the garbled terminal in #1733.
//
// A real browser is the only place this can be checked: it needs a real layout
// engine to produce the 0x0, a real xterm to have a construction default, and
// a real frame loop to settle. The socket is faked — the claim is about what
// the hook says, not about a server.

class ProbePush {
  constructor() { this.handlers = {} }
  receive(status, cb) { (this.handlers[status] ||= []).push(cb); return this }
  reply(status, payload) { (this.handlers[status] || []).forEach((cb) => cb(payload)) }
}

class ProbeSocket {
  constructor() {
    this.pushes = []
    this.joins = []
    this.events = {}
    this.disconnected = false
    this.reconnectTimer = { scheduleTimeout: () => {} }
  }
  onError() {}
  onClose() {}
  connect() {}
  disconnect() { this.disconnected = true }
  channel(topic, params) {
    this.topic = topic
    const socket = this
    return {
      on(event, cb) { (socket.events[event] ||= []).push(cb) },
      onError() {},
      join() {
        const push = new ProbePush()
        socket.joins.push({ params: params(), push })
        return push
      },
      push(event, payload) {
        socket.pushes.push({ event, payload })
        return new ProbePush()
      }
    }
  }
  emit(event, payload) { (this.events[event] || []).forEach((cb) => cb(payload)) }
  pushesFor(event) { return this.pushes.filter((p) => p.event === event) }
}

const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()))

// A pane shaped like the dashboard's: fixed height, `p-2`, and — the part that
// matters — inside a parent that has no box at all when the hook mounts.
function hiddenPane() {
  const parent = document.createElement("div")
  parent.style.display = "none"
  const el = document.createElement("div")
  el.style.width = "800px"
  el.style.height = "400px"
  el.style.padding = "8px"
  parent.appendChild(el)
  document.body.appendChild(parent)
  return { parent, el }
}

async function remountChecks() {
  // -- a first mount, on a pane that is already laid out --------------------
  const first = hiddenPane()
  first.parent.style.display = "block"

  const firstSocket = new ProbeSocket()
  const firstHandle = createSessionTerminal(first.el, {
    sessionId: "probe",
    socket: firstSocket
  })

  await frame()
  const firstJoin = firstSocket.joins[0]
  check(
    "first-mount-joins-with-a-fitted-geometry",
    firstJoin ? `${firstJoin.params.cols}x${firstJoin.params.rows}` : "never joined",
    firstJoin && firstJoin.params.cols > 0 && firstJoin.params.rows > 0
  )

  if (!firstJoin) return

  const fitted = { cols: firstJoin.params.cols, rows: firstJoin.params.rows }

  firstJoin.push.reply("ok", { seq: 0, mode: "snapshot", resized: false })
  firstSocket.emit("snapshot", { seq: 0, data: "first" })

  // Navigate away.
  firstHandle.dispose()
  first.parent.remove()

  // -- and back: mounted before the page has been laid out ------------------
  const second = hiddenPane()
  const socket = new ProbeSocket()
  const handle = createSessionTerminal(second.el, {
    sessionId: "probe",
    socket
  })

  check(
    "remount-waits-for-a-box-before-joining",
    `joins=${socket.joins.length}`,
    socket.joins.length === 0
  )

  // The layout settles a frame later, exactly as a LiveView patch does.
  second.parent.style.display = "block"

  for (let i = 0; i < 30 && socket.joins.length === 0; i++) await frame()

  const join = socket.joins[0]
  if (!join) {
    check("remount-joins-with-the-fitted-geometry-not-xterms-default", "never joined", false)
    return
  }

  check(
    "remount-joins-with-the-fitted-geometry-not-xterms-default",
    join
      ? `join ${join.params.cols}x${join.params.rows}, fitted ${fitted.cols}x${fitted.rows}`
      : "never joined",
    join && join.params.cols === fitted.cols && join.params.rows === fitted.rows
  )

  check(
    "remount-renders-at-the-fitted-geometry",
    `term ${handle.term.cols}x${handle.term.rows}, fitted ${fitted.cols}x${fitted.rows}`,
    handle.term.cols === fitted.cols && handle.term.rows === fitted.rows
  )

  // The pane is told outright rather than only through the join params: a
  // resumed join replays bytes for whatever geometry the pane has, so the
  // remount has to re-announce its own alongside the replay.
  join.push.reply("ok", { seq: 12, mode: "resumed", resized: true })
  socket.emit("meta", { cols: fitted.cols, rows: fitted.rows, attached_clients: 1 })

  for (let i = 0; i < 30 && socket.pushesFor("resize").length === 0; i++) await frame()

  const resizes = socket.pushesFor("resize")
  check(
    "remount-sends-its-geometry-to-the-pane",
    resizes.length ? JSON.stringify(resizes[0].payload) : "no resize pushed",
    resizes.length > 0 &&
      resizes[0].payload.cols === fitted.cols &&
      resizes[0].payload.rows === fitted.rows
  )

  // The join said it resized the pane, so the snapshot/replay it is about to
  // paint was laid out for the old geometry. Nothing the client can do fixes
  // that; the agent has to repaint.
  check(
    "a-join-that-resized-the-pane-forces-a-redraw",
    `redraws=${socket.pushesFor("redraw").length}`,
    socket.pushesFor("redraw").length === 1
  )

  // -- AC 4: a window resize while the page is open still refits -----------
  //
  // The settle only covers the mount. Widening the pane afterwards is the
  // `ResizeObserver` path, and it has to keep working: this is the drag the
  // debounce exists for, and the one bd-3r2otb's fit arithmetic serves.
  second.el.style.width = "500px"
  second.el.style.height = "300px"

  for (let i = 0; i < 60 && socket.pushesFor("resize").length < 2; i++) await frame()

  const afterResize = socket.pushesFor("resize").at(-1)
  check(
    "a-window-resize-refits-and-tells-the-pane",
    afterResize
      ? `${JSON.stringify(afterResize.payload)} term ${handle.term.cols}x${handle.term.rows}`
      : "no second resize",
    afterResize &&
      afterResize.payload.cols < fitted.cols &&
      afterResize.payload.rows < fitted.rows &&
      afterResize.payload.cols === handle.term.cols &&
      afterResize.payload.rows === handle.term.rows
  )

  handle.dispose()

  // A join that changed nothing must not churn the pane every client shares.
  const third = hiddenPane()
  third.parent.style.display = "block"
  const quiet = new ProbeSocket()
  const quietHandle = createSessionTerminal(third.el, { sessionId: "probe", socket: quiet })

  for (let i = 0; i < 30 && quiet.joins.length === 0; i++) await frame()
  quiet.joins[0].push.reply("ok", { seq: 12, mode: "resumed", resized: false })
  for (let i = 0; i < 10; i++) await frame()

  check(
    "a-join-that-changed-nothing-does-not-redraw",
    `redraws=${quiet.pushesFor("redraw").length}`,
    quiet.pushesFor("redraw").length === 0
  )

  quietHandle.dispose()

  // A tab that never paints never runs a frame callback. The settle cannot be
  // the only thing deciding when this terminal connects — the page's own stall
  // notice arms at 8s and would tell the operator to reload a working session.
  const stuck = hiddenPane()
  const stuckSocket = new ProbeSocket()
  const stuckHandle = createSessionTerminal(stuck.el, {
    sessionId: "probe",
    socket: stuckSocket,
    schedule: () => {}
  })

  await new Promise((resolve) => setTimeout(resolve, 1400))

  check(
    "a-tab-that-never-paints-still-attaches",
    `joins=${stuckSocket.joins.length}`,
    stuckSocket.joins.length === 1
  )

  stuckHandle.dispose()
  stuck.parent.remove()
  second.parent.remove()
  third.parent.remove()
}

// -- bd-4tjw34: two clients, one pane -----------------------------------------
//
// The pane is shared and last-writer-wins, so a second browser client attached
// at a different size moves the geometry out from under this one. Before this,
// the `meta` that announced it only updated the size label: the xterm stayed
// laid out for a size the pane no longer had, and stayed garbled until a
// manual resize or a reload.
//
// `session_geometry_test.mjs` proves the policy under `node --test`. What only
// a browser can show is that it lands on the *real* xterm — that the adopted
// geometry is what the renderer is actually drawing at, and that focus reaches
// the reclaim through a real `focusin` rather than through a call in a test.

async function adoptionChecks() {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

  const until = async (predicate, ms = 1500) => {
    for (let waited = 0; waited < ms && !predicate(); waited += 20) await sleep(20)
    return predicate()
  }

  const pane = hiddenPane()
  pane.parent.style.display = "block"

  const socket = new ProbeSocket()
  const reports = []
  const handle = createSessionTerminal(pane.el, {
    sessionId: "probe",
    socket,
    onMeta: (meta, info) => reports.push({ meta, info })
  })

  if (!(await until(() => socket.joins.length > 0))) {
    check("adopt-probe-joins", "never joined", false)
    handle.dispose()
    pane.parent.remove()
    return
  }

  socket.joins[0].push.reply("ok", { seq: 0, mode: "snapshot", resized: false })
  socket.emit("snapshot", { seq: 0, data: "" })

  await until(() => socket.pushesFor("resize").length > 0)

  const own = { cols: handle.term.cols, rows: handle.term.rows }
  socket.emit("meta", { cols: own.cols, rows: own.rows, attached_clients: 1 })

  const ownReport = reports.at(-1)
  check(
    "this-clients-own-geometry-is-not-reported-as-adopted",
    ownReport ? `${JSON.stringify(ownReport.meta)} adopted=${ownReport.info.adopted}` : "no meta",
    ownReport && ownReport.info.adopted === false
  )

  const settled = socket.pushesFor("resize").length

  // A second client, wider and taller, wins the pane.
  const theirs = { cols: own.cols + 17, rows: own.rows + 5 }
  socket.emit("meta", { ...theirs, attached_clients: 2 })

  check(
    "another-clients-geometry-is-adopted-by-the-real-xterm",
    `term ${handle.term.cols}x${handle.term.rows}, pane ${theirs.cols}x${theirs.rows}`,
    handle.term.cols === theirs.cols && handle.term.rows === theirs.rows
  )

  const adoptedReport = reports.at(-1)
  check(
    "the-adopted-geometry-is-labelled-as-adopted",
    adoptedReport
      ? `${JSON.stringify(adoptedReport.meta)} adopted=${adoptedReport.info.adopted}`
      : "no meta",
    adoptedReport &&
      adoptedReport.info.adopted === true &&
      adoptedReport.meta.cols === theirs.cols &&
      adoptedReport.meta.rows === theirs.rows
  )

  // ...and the screen is genuinely laid out for it: a full row at the pane's
  // width fills exactly one line and does not wrap onto the next.
  await writeAsync(handle.term, "\r\n" + "#".repeat(theirs.cols))
  const filled = lineText(handle.term, handle.term.buffer.active.cursorY)
  const below = lineText(handle.term, handle.term.buffer.active.cursorY + 1)
  check(
    "the-adopted-screen-renders-without-wrapping",
    `row=${filled ? filled.length : "null"} of ${theirs.cols}, next=${JSON.stringify(below)}`,
    filled && filled.length === theirs.cols && (below === null || below === "")
  )

  // Idle. However long the debounce is given, nothing answers the meta —
  // this is the edge a resize fight would have to cross.
  await sleep(400)
  check(
    "a-meta-is-never-answered-with-a-resize",
    `resizes after the meta = ${socket.pushesFor("resize").length - settled}`,
    socket.pushesFor("resize").length === settled
  )

  // Interacting takes it back. `focus()` is the real path: the hook listens
  // for `focusin`, which is what a click or a Tab into the pane produces.
  handle.term.focus()

  const reclaimed = await until(() => socket.pushesFor("resize").length > settled)
  const push = socket.pushesFor("resize").at(-1)
  check(
    "focus-reclaims-the-pane-at-this-clients-own-geometry",
    push ? `${JSON.stringify(push.payload)} own ${own.cols}x${own.rows}` : "no resize",
    reclaimed && push.payload.cols === own.cols && push.payload.rows === own.rows
  )

  check(
    "reclaiming-puts-the-real-xterm-back-at-its-own-geometry",
    `term ${handle.term.cols}x${handle.term.rows}, own ${own.cols}x${own.rows}`,
    handle.term.cols === own.cols && handle.term.rows === own.rows
  )

  // A browser resize reclaims too — and it is the one interaction the pane's
  // own `ResizeObserver` cannot be trusted to report, because adopting a
  // geometry bigger than the container puts a scrollbar on it and that fires
  // the observer as well. While adopted, only `window`'s own resize counts.
  socket.emit("meta", { ...theirs, attached_clients: 2 })
  const beforeResize = socket.pushesFor("resize").length

  pane.el.style.width = "560px"
  pane.el.style.height = "300px"
  window.dispatchEvent(new Event("resize"))

  const shrank = await until(() => socket.pushesFor("resize").length > beforeResize)
  const afterResize = socket.pushesFor("resize").at(-1)

  check(
    "a-browser-resize-reclaims-an-adopted-pane",
    afterResize
      ? `${JSON.stringify(afterResize.payload)} term ${handle.term.cols}x${handle.term.rows}`
      : "no resize",
    shrank &&
      afterResize.payload.cols < theirs.cols &&
      afterResize.payload.rows < theirs.rows &&
      afterResize.payload.cols === handle.term.cols &&
      afterResize.payload.rows === handle.term.rows
  )

  handle.dispose()
  pane.parent.remove()
}

// -- bd-9myzv8: the session dock's collapse / expand cycle --------------------
//
// In the dock the terminal is not merely re-mounted on navigation — it is
// *destroyed* on every collapse and built again on every expand, because the
// acceptance criterion is that a strip of collapsed windows holds zero xterm
// instances and zero live sockets. Three things have to survive that:
//
//   * the resume point, handed back in as `lastSeq`, so the expand replays
//     what the window missed instead of re-snapshotting;
//   * the screen: a resumed replay is a *delta*, and a delta painted onto a
//     terminal that has just been constructed has nothing under it, so the
//     agent has to be asked to repaint;
//   * the scroll offset, which a sticky view's re-parent zeroes.
//
// And the keyboard rule: an expanded terminal takes every key, so the one way
// out of it has to work and must never reach the agent.

// A key event for a named key. The probe's own `keydown` helper spells
// `code`/`keyCode` from a single character, and xterm resolves a keystroke to
// bytes from `keyCode` — a synthetic event without one produces nothing at all,
// which would make every check below pass vacuously.
const KEY_CODES = { Escape: 27, Enter: 13, Tab: 9 }

function rawKeydown(term, key, { ctrl = false, shift = false, meta = false } = {}) {
  const target = term.element.querySelector(".xterm-helper-textarea") || term.element
  target.dispatchEvent(
    new KeyboardEvent("keydown", {
      key,
      code: key,
      keyCode: KEY_CODES[key],
      which: KEY_CODES[key],
      ctrlKey: ctrl,
      shiftKey: shift,
      metaKey: meta,
      bubbles: true,
      cancelable: true
    })
  )
}

function stdinText(socket) {
  return socket
    .pushesFor("stdin")
    .map((p) => {
      const decoded = decodeFrame(p.payload)
      return decoded ? new TextDecoder().decode(decoded.payload) : ""
    })
    .join("")
}

async function dockChecks() {
  // -- expanding a window resumes from where the last one stopped -----------
  const pane = hiddenPane()
  pane.parent.style.display = "block"

  const socket = new ProbeSocket()
  const released = []
  const handle = createSessionTerminal(pane.el, {
    sessionId: "dock",
    socket,
    lastSeq: 4096,
    onReleaseFocus: () => released.push(true)
  })

  for (let i = 0; i < 30 && socket.joins.length === 0; i++) await frame()
  const join = socket.joins[0]
  if (!join) {
    check("expand-resumes-from-the-remembered-offset", "never joined", false)
    return
  }

  check(
    "expand-resumes-from-the-remembered-offset",
    `last_seq=${join.params.last_seq}`,
    join.params.last_seq === 4096
  )

  // A resumed replay onto a screen that has just been constructed is a delta
  // with nothing under it. The geometry did not change — `resized: false` —
  // so nothing else would ask, and the window would come back holding a
  // fragment of a repaint.
  join.push.reply("ok", { seq: 4096, mode: "resumed", resized: false })
  for (let i = 0; i < 10; i++) await frame()

  check(
    "a-resumed-join-onto-a-fresh-terminal-forces-a-redraw",
    `redraws=${socket.pushesFor("redraw").length}`,
    socket.pushesFor("redraw").length === 1
  )

  // -- the keyboard rule ----------------------------------------------------
  rawKeydown(handle.term, "Escape")
  await tick()

  check(
    "a-plain-escape-reaches-the-agent",
    JSON.stringify(stdinText(socket)),
    stdinText(socket).includes("\u001b") && released.length === 0
  )

  handle.focus()
  const beforeRelease = document.activeElement
  rawKeydown(handle.term, "Escape", { ctrl: true, shift: true })
  await tick()

  check(
    "ctrl-shift-escape-releases-focus-and-never-reaches-the-agent",
    `released=${released.length} stdin=${JSON.stringify(stdinText(socket))}`,
    released.length === 1 && stdinText(socket) === "\u001b"
  )

  check(
    "releasing-focus-really-blurs-the-terminal",
    `was ${beforeRelease && beforeRelease.className}, now ${document.activeElement && document.activeElement.className}`,
    !handle.term.element.contains(document.activeElement)
  )

  // -- the scroll offset across a sticky re-parent --------------------------
  //
  // `LiveSocket.replaceMain` moves the dock through a *detached* container, and
  // detaching an element zeroes `scrollTop` on every scrollable node inside it
  // — xterm's viewport included, which scrolls the buffer to the top of the
  // scrollback. `phx:navigate` fires while xterm still holds the right value
  // (the browser has not dispatched the resulting `scroll` event yet), which
  // is the one moment it can be captured.
  await writeAsync(handle.term, new TextEncoder().encode("line\r\n".repeat(400)))
  handle.term.scrollToBottom()
  for (let i = 0; i < 5; i++) await frame()

  const bottom = handle.term.buffer.active.viewportY
  handle.rememberScroll()

  const viewport = pane.el.querySelector(".xterm-viewport")
  viewport.scrollTop = 0
  for (let i = 0; i < 5 && handle.term.buffer.active.viewportY !== 0; i++) await frame()
  const disturbed = handle.term.buffer.active.viewportY

  handle.restoreScroll()
  for (let i = 0; i < 5; i++) await frame()

  check(
    "a-reparent-does-not-leave-the-terminal-scrolled-to-the-top",
    `bottom=${bottom} after the reparent=${disturbed} restored=${handle.term.buffer.active.viewportY}`,
    bottom > 0 && disturbed === 0 && handle.term.buffer.active.viewportY === bottom
  )

  // -- collapsing holds nothing ---------------------------------------------
  handle.dispose()

  check(
    "collapsing-tears-down-the-xterm-and-closes-the-socket",
    `xterms in the pane=${pane.el.querySelectorAll(".xterm").length} disconnected=${socket.disconnected}`,
    pane.el.querySelectorAll(".xterm").length === 0 && socket.disconnected === true
  )

  pane.parent.remove()
}

window.__arbProbe = probe
