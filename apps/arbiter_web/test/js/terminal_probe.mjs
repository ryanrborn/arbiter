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
    this.reconnectTimer = { scheduleTimeout: () => {} }
  }
  onError() {}
  onClose() {}
  connect() {}
  disconnect() {}
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
  second.parent.remove()
  third.parent.remove()
}

window.__arbProbe = probe
