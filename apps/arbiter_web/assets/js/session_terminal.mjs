// xterm.js, wired to phase 4's channel (bd-c76fu9, phase 5 of
// `docs/browser-hosted-coordinator-sessions.md` §6).
//
// This is the DOM half of the browser terminal: it builds the `Terminal` and
// the **canvas** renderer (§6.2), measures the pane, and hands everything that
// can be reasoned about without a DOM to a module that is unit-tested under
// `node --test` — the protocol to `session_stream.mjs`, the fit arithmetic to
// `session_fit.mjs`, the copy/paste policy to `session_keys.mjs`.
//
// Everything imported here is either vendored (`../vendor/xterm/*`, see that
// directory's README) or already a Mix dependency (`phoenix`). There is no
// npm in this repo and this file does not introduce one (§6.1).

import { Terminal } from "../vendor/xterm/xterm.js"
import { CanvasAddon } from "../vendor/xterm/addon-canvas.js"
import { Socket } from "phoenix"

import { SessionStream } from "./session_stream.mjs"
import { fitGeometry, settleFit } from "./session_fit.mjs"
import { handleTerminalKey } from "./session_keys.mjs"

// §6.3: the server holds 30k lines and the transcript holds everything, so the
// client only needs what the operator will actually scroll.
const SCROLLBACK = 5000

// A `ResizeObserver` fires once per animation frame while a window is being
// dragged. Fitting is a relayout, and every `resize` that reaches the server
// re-lays-out the pane for *every* attached client and makes the agent redraw,
// so both steps wait for the drag to stop. The two debounces run in series —
// the pane settles within ~200 ms of the last frame.
const FIT_DEBOUNCE_MS = 100

// How long the mount will wait on the frame loop before attaching anyway
// (bd-14b11h). `requestAnimationFrame` does not fire in a tab that never
// paints, and the page's own stall notice arms at 8s, so the settle cannot be
// the only thing that decides when this terminal connects.
const SETTLE_DEADLINE_MS = 1000

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
 * `onUsage(payload)` (§7.5, phase 7 — the live cost HUD feed), `onError(err)`.
 *
 * `socket` and `schedule` are test seams: `apps/arbiter_web/test/js/terminal_probe.mjs`
 * drives the real hook against a phoenix.js stand-in and a real frame loop.
 */
export function createSessionTerminal(el, options = {}) {
  const {
    sessionId,
    endpoint = "/session",
    onStatus = () => {},
    onExit = () => {},
    onMeta = () => {},
    onUsage = () => {},
    onError = () => {},
    schedule = (cb) => requestAnimationFrame(cb)
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

  // §6.3: the fit is ours, not `@xterm/addon-fit`'s. The addon sizes the
  // terminal from `getComputedStyle(parent).height`, which Chrome resolves to
  // the **border box** under `box-sizing: border-box` — Tailwind's preflight
  // puts every element in that mode — so the pane's own `p-2` was counted as
  // usable terminal space. With a 20px cell that is exactly one row too many,
  // and the bottom line of the agent's UI was clipped in half.
  const applyFit = () => {
    const geometry = paneGeometry(el, term)
    if (!geometry) return null

    if (geometry.cols !== term.cols || geometry.rows !== term.rows) {
      clearRenderer(term)
      term.resize(geometry.cols, geometry.rows)
    }

    return geometry
  }

  // No connect params. The dashboard is loopback-only by design (§10.4) and
  // `ArbiterWeb.SessionSocket` trusts a loopback peer without a token, so the
  // page has none to send; reaching the dashboard from elsewhere is Remote
  // Control's job (§8), not a second auth scheme here. The socket also accepts
  // a `caller_session_id` for §10.1's self-kill guard, but a *browser* is not
  // running inside a coordinator session and has nothing truthful to declare
  // there - the clients that do (an agent's own tooling) pass it themselves.
  const socket =
    options.socket ||
    new Socket(endpoint, {
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
      // The reply to *our* join: `resized` is the server saying that the
      // cols/rows we brought changed the pane. The snapshot (or the replay) we
      // are about to paint was therefore laid out by the pane for the old
      // geometry rather than redrawn by the agent for the new one — exactly
      // the garble a LiveView navigation back to this page produced
      // (bd-14b11h). Only the agent can fix it, so it is asked to.
      joined: (reply) => {
        if (reply && reply.resized) stream.redraw()
      },
      status: onStatus,
      meta: (meta) => onMeta(meta),
      usage: (payload) => onUsage(payload),
      exit: (payload) => onExit(payload),
      error: (err) => onError(err)
    }
  })

  term.onData((data) => stream.send(data))
  // Some sequences (a mouse report, a bracketed paste of binary) arrive as a
  // latin1 string of raw bytes rather than text; they must not be UTF-8
  // encoded on the way out.
  term.onBinary((data) => stream.sendBytes(latin1Bytes(data)))

  term.attachCustomKeyEventHandler((event) =>
    handleTerminalKey(event, {
      term,
      clipboard: typeof navigator === "undefined" ? null : navigator.clipboard,
      // A blocked clipboard is reported rather than swallowed: "Ctrl+Shift+V
      // did nothing" is the one outcome an operator cannot debug.
      onClipboardError: (error) =>
        onError({ code: "clipboard_blocked", detail: String((error && error.message) || error) })
    })
  )

  // Clicking anywhere in the pane - including its padding - focuses the
  // terminal, which is what an operator expects from something that looks like
  // a terminal. Selection is left to xterm, so a click that *drags* does not
  // steal the selection it just made.
  el.addEventListener("mousedown", (event) => {
    if (event.button === 0 && !term.hasSelection()) term.focus()
  })

  let disposed = false
  let fitTimer = null
  const scheduleFit = () => {
    if (fitTimer) clearTimeout(fitTimer)
    fitTimer = setTimeout(() => {
      fitTimer = null
      const geometry = applyFit()
      // Only a geometry we actually measured is pushed. A pane that has not
      // been laid out reports 0x0, and that number resizes the pane *every*
      // attached client shares.
      if (geometry) stream.resize(geometry.cols, geometry.rows)
    }, FIT_DEBOUNCE_MS)
  }

  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(scheduleFit) : null
  if (observer) observer.observe(el)

  // The dashboard's mono face is a **webfont** (Geist Mono, from Google
  // Fonts), and xterm measures its cell exactly once — inside `open()`, with
  // whatever fallback the browser had resolved at that instant. Nothing in
  // xterm watches `document.fonts`, so without this the pane keeps a cell size
  // the text no longer has and every fit computed from it is off, which is the
  // second way the bottom row ends up clipped.
  const fonts = typeof document === "undefined" ? null : document.fonts
  if (fonts && fonts.ready) {
    fonts.ready
      .then(() => {
        if (disposed) return
        remeasure(term)
        scheduleFit()
      })
      .catch(() => {
        /* no webfont arrived; the fallback metrics were right all along */
      })
  }

  // The canvas renderer holds a *resolved* palette, so it does not follow the
  // CSS custom properties the way the pane's own background does. Without
  // this, flipping the dashboard theme leaves a light terminal sitting in a
  // dark frame (or the reverse) until the page is reloaded.
  //
  // `assets/js/theme.js` funnels every path - the toggle's `phx:set-theme`,
  // another tab's `storage` event, the pre-paint default - through the
  // `data-theme` attribute on <html>, so observing that attribute covers all
  // of them. The media query is the remaining case: under `system` there is no
  // attribute to change when the OS flips.
  const applyTheme = () => {
    term.options.theme = readTheme(el)
  }

  const themeObserver =
    typeof MutationObserver === "function" ? new MutationObserver(applyTheme) : null
  if (themeObserver) {
    themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"]
    })
  }

  const colorScheme =
    typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : null
  if (colorScheme && colorScheme.addEventListener) colorScheme.addEventListener("change", applyTheme)

  // §6.3 / bd-14b11h: connect only once the pane has a box.
  //
  // This is deliberately not `applyFit(); stream.connect()`. A LiveView
  // navigation back to this page mounts the hook *inside* the DOM patch, and
  // the pane it is handed can still measure 0x0; `fitGeometry` rightly refuses
  // to size that, and a single synchronous attempt therefore left xterm on the
  // 80x24 it constructs with. That default is not inert — it is what the join
  // params carry, so it resized the pane every attached client shares and the
  // snapshot captured in the same call came back reflowed for a geometry the
  // agent had not redrawn at.
  //
  // So: measure until there is something to measure, then join with the real
  // geometry, then tell the pane outright. The join params alone are not
  // enough — a `resumed` join replays bytes for whatever size the pane is
  // already at, and re-announcing is what reconciles the two.
  let attached = false

  const attach = (geometry) => {
    if (disposed || attached) return
    attached = true

    stream.connect()

    // `null` means nothing measurable was ever found. It still attaches; it
    // just leaves the pane's geometry alone until the `ResizeObserver` above
    // sees a box, because a geometry we did not measure is a geometry that
    // resizes the pane every other client shares.
    if (geometry) stream.resize(geometry.cols, geometry.rows)
  }

  const cancelSettle = settleFit({ measure: applyFit, schedule, onSettled: attach })

  // A laid-out pane has already attached synchronously above and needs no
  // timer. Anything else gets one: a tab that never paints never runs a frame
  // callback, and a terminal that waits for one would sit at "connecting…"
  // until the operator looked at it.
  const settleDeadline = attached
    ? null
    : setTimeout(() => {
        cancelSettle()
        attach(applyFit())
      }, SETTLE_DEADLINE_MS)

  return {
    term,
    stream,
    renderer,
    focus: () => term.focus(),
    fit: applyFit,
    refit: scheduleFit,
    detach: () => stream.detach(),
    kill: () => stream.kill(),
    applyTheme,
    dispose() {
      disposed = true
      cancelSettle()
      if (settleDeadline) clearTimeout(settleDeadline)
      if (fitTimer) clearTimeout(fitTimer)
      if (observer) observer.disconnect()
      if (themeObserver) themeObserver.disconnect()
      if (colorScheme && colorScheme.removeEventListener) {
        colorScheme.removeEventListener("change", applyTheme)
      }
      stream.dispose()
      term.dispose()
    }
  }
}

// -- §6.3 fit ----------------------------------------------------------------

// The pane's **content box**. `clientHeight`/`clientWidth` already exclude
// borders and any scrollbar the element itself shows, so only its padding is
// left to take off — and taking it off is the whole fix: the old fit addon
// measured a box that included it.
function paneGeometry(el, term) {
  const cell = cellSize(term)
  if (!cell) return null

  const style = getComputedStyle(el)

  return fitGeometry({
    width: el.clientWidth - px(style.paddingLeft) - px(style.paddingRight),
    height: el.clientHeight - px(style.paddingTop) - px(style.paddingBottom),
    cellWidth: cell.width,
    cellHeight: cell.height,
    scrollbarWidth: cell.scrollbarWidth
  })
}

// xterm's measured cell, read where `@xterm/addon-fit` read it.
// `dimensions.css` is the CSS-pixel geometry the renderer actually draws
// with, which is the one that has to divide into a CSS-pixel box.
function cellSize(term) {
  const core = term._core
  const service = core && core._renderService
  const dimensions = service && service.dimensions
  const cell = dimensions && dimensions.css && dimensions.css.cell

  if (!cell || !(cell.width > 0) || !(cell.height > 0)) return null

  const viewport = core.viewport

  return {
    width: cell.width,
    height: cell.height,
    // With `scrollback: 0` xterm shows no viewport scrollbar at all.
    scrollbarWidth:
      term.options.scrollback === 0 || !viewport ? 0 : viewport.scrollBarWidth || 0
  }
}

// What the fit addon did before every resize: drop the renderer's cached
// layers so the new geometry is drawn rather than stretched over the old one.
function clearRenderer(term) {
  const service = term._core && term._core._renderService
  if (service && typeof service.clear === "function") service.clear()
}

// Re-measure the cell after a webfont arrives. xterm only measures inside
// `open()`, and it does not watch `document.fonts`.
function remeasure(term) {
  const service = term._core && term._core._charSizeService
  if (service && typeof service.measure === "function") service.measure()
}

function px(value) {
  const parsed = parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

// -- helpers ------------------------------------------------------------------

function latin1Bytes(text) {
  const bytes = new Uint8Array(text.length)
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff
  return bytes
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
