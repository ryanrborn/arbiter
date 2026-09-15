// xterm.js, wired to phase 4's channel (bd-c76fu9, phase 5 of
// `docs/browser-hosted-coordinator-sessions.md` §6).
//
// This is the DOM half of the browser terminal: it builds the `Terminal`, the
// **canvas** renderer (§6.2) and the fit addon, and hands the protocol to
// `session_stream.mjs`, which is DOM-free and unit-tested under `node --test`.
//
// Everything imported here is either vendored (`../vendor/xterm/*`, see that
// directory's README) or already a Mix dependency (`phoenix`). There is no
// npm in this repo and this file does not introduce one (§6.1).

import { Terminal } from "../vendor/xterm/xterm.js"
import { CanvasAddon } from "../vendor/xterm/addon-canvas.js"
import { FitAddon } from "../vendor/xterm/addon-fit.js"
import { Socket } from "phoenix"

import { SessionStream } from "./session_stream.mjs"

// §6.3: the server holds 30k lines and the transcript holds everything, so the
// client only needs what the operator will actually scroll.
const SCROLLBACK = 5000

// A `ResizeObserver` fires once per animation frame while a window is being
// dragged. Fitting is a relayout, and every `resize` that reaches the server
// re-lays-out the pane for *every* attached client and makes the agent redraw,
// so both steps wait for the drag to stop. The two debounces run in series —
// the pane settles within ~200 ms of the last frame.
const FIT_DEBOUNCE_MS = 100

const FALLBACK_THEME = {
  background: "#12151b",
  foreground: "#d6dae2",
  cursor: "#a3e635",
  selectionBackground: "#33415580"
}

const DIM = "[2m"
const RESET = "[0m"

/**
 * Mount a terminal into `el` and attach it to `sessionId`.
 *
 * Callbacks, all optional: `onStatus(state)` with "connecting" | "live" |
 * "reconnecting" | "detached" | "ended", `onExit(payload)`, `onMeta(meta)`,
 * `onError(err)`.
 */
export function createSessionTerminal(el, options = {}) {
  const {
    sessionId,
    endpoint = "/session",
    token = null,
    callerSessionId = null,
    onStatus = () => {},
    onExit = () => {},
    onMeta = () => {},
    onError = () => {}
  } = options

  const term = new Terminal({
    scrollback: SCROLLBACK,
    convertEol: false,
    cursorBlink: true,
    // §6.3: leave Option/Alt alone so the agent's own meta bindings work, and
    // so `Ctrl+C` keeps meaning SIGINT rather than "copy".
    macOptionIsMeta: false,
    allowProposedApi: true,
    fontFamily: cssValue(el, "--font-mono", "ui-monospace, SFMono-Regular, Menlo, monospace"),
    fontSize: 13,
    lineHeight: 1.2,
    theme: readTheme(el)
  })

  const fit = new FitAddon()
  term.loadAddon(fit)
  term.open(el)

  // §6.2: canvas, never WebGL. Browsers cap live WebGL contexts at roughly
  // 8-16 and the dashboard is a multi-panel app the operator keeps open across
  // tabs; a lost context renders as a *blank terminal* on the primary
  // interface, and recovering from one needs explicit `onContextLoss` handling
  // and a renderer rebuild. Canvas degrades gracefully, and if constructing it
  // fails xterm falls back to the DOM renderer on its own.
  let renderer = "canvas"
  try {
    term.loadAddon(new CanvasAddon())
  } catch (error) {
    renderer = "dom"
    console.warn("[session-terminal] canvas renderer unavailable, using the DOM renderer", error)
  }

  safeFit(fit)

  const socket = new Socket(endpoint, {
    params: () => {
      const params = {}
      if (token) params.token = token
      // Only ever used to *refuse* an action (§10.1's self-kill guard), so a
      // client understating it can only reduce its own privileges.
      if (callerSessionId) params.caller_session_id = callerSessionId
      return params
    },
    // Reconnect briskly: the point is to be back before the operator is.
    reconnectAfterMs: (tries) => [100, 250, 500, 1000, 2000][tries - 1] || 2000
  })

  const stream = new SessionStream({
    socket,
    sessionId,
    geometry: () => ({ cols: term.cols, rows: term.rows }),
    sink: {
      // Straight from the socket into xterm: the bytes are never decoded in
      // transit, because a PTY read boundary lands mid-UTF-8 and mid-escape
      // and xterm is the thing that reassembles them.
      write: (payload) => {
        if (payload.length > 0) term.write(payload)
      },
      repaint: (_seq, data, info) => {
        term.reset()
        if (data) term.write(data)
        if (info && info.rejoin) {
          term.writeln("")
          term.writeln(DIM + "-- reattached; the scrollback above was repainted --" + RESET)
        }
      },
      status: onStatus,
      meta: (meta) => onMeta(meta),
      exit: (payload) => onExit(payload),
      error: (err) => onError(err)
    }
  })

  term.onData((data) => stream.send(data))
  // Some sequences (a mouse report, a bracketed paste of binary) arrive as a
  // latin1 string of raw bytes rather than text; they must not be UTF-8
  // encoded on the way out.
  term.onBinary((data) => stream.sendBytes(latin1Bytes(data)))

  term.attachCustomKeyEventHandler((event) => handleKey(event, term, stream))

  // Clicking anywhere in the pane - including its padding - focuses the
  // terminal, which is what an operator expects from something that looks like
  // a terminal. Selection is left to xterm, so a click that *drags* does not
  // steal the selection it just made.
  el.addEventListener("mousedown", (event) => {
    if (event.button === 0 && !term.hasSelection()) term.focus()
  })

  let fitTimer = null
  const scheduleFit = () => {
    if (fitTimer) clearTimeout(fitTimer)
    fitTimer = setTimeout(() => {
      fitTimer = null
      safeFit(fit)
      stream.resize(term.cols, term.rows)
    }, FIT_DEBOUNCE_MS)
  }

  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(scheduleFit) : null
  if (observer) observer.observe(el)

  stream.connect()

  return {
    term,
    stream,
    fit,
    renderer,
    focus: () => term.focus(),
    refit: scheduleFit,
    detach: () => stream.detach(),
    kill: () => stream.kill(),
    dispose() {
      if (fitTimer) clearTimeout(fitTimer)
      if (observer) observer.disconnect()
      stream.dispose()
      term.dispose()
    }
  }
}

// -- §6.3 copy/paste ----------------------------------------------------------

// `Ctrl/Cmd+Shift+C` copies the selection and `Ctrl/Cmd+Shift+V` pastes, so
// that plain `Ctrl+C` still sends SIGINT to the agent - the single most common
// terminal papercut, and the one that matters most when the thing on the other
// end is an agent mid-turn.
function handleKey(event, term, stream) {
  if (event.type !== "keydown") return true
  if (!(event.ctrlKey || event.metaKey) || !event.shiftKey) return true

  const key = event.key.toLowerCase()

  if (key === "c") {
    const selection = term.getSelection()
    if (selection) writeClipboard(selection)
    return false
  }

  if (key === "v") {
    readClipboard().then((text) => {
      // Chunked into stdin frames by `SessionStream` - a paste is not a
      // keystroke and a 200 KB one must not become a single socket frame.
      if (text) stream.paste(text)
    })
    return false
  }

  return true
}

function writeClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => {})
  }
}

function readClipboard() {
  if (navigator.clipboard && navigator.clipboard.readText) {
    return navigator.clipboard.readText().catch(() => null)
  }
  return Promise.resolve(null)
}

// -- helpers ------------------------------------------------------------------

function latin1Bytes(text) {
  const bytes = new Uint8Array(text.length)
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff
  return bytes
}

// `fit()` throws if the element has not been laid out yet - a background tab,
// a `display: none` ancestor, a mount before first paint. Not an error: the
// `ResizeObserver` fires again the moment it has a box.
function safeFit(fit) {
  try {
    fit.fit()
  } catch (_error) {
    /* not laid out yet */
  }
}

function cssValue(el, name, fallback) {
  const value = getComputedStyle(el).getPropertyValue(name)
  return value && value.trim() !== "" ? value.trim() : fallback
}

function readTheme(el) {
  return {
    background: cssValue(el, "--arb-term-bg", FALLBACK_THEME.background),
    foreground: cssValue(el, "--arb-term-fg", FALLBACK_THEME.foreground),
    cursor: cssValue(el, "--arb-term-cursor", FALLBACK_THEME.cursor),
    selectionBackground: cssValue(el, "--arb-term-selection", FALLBACK_THEME.selectionBackground)
  }
}
