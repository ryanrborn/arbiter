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
  const proposed = handle.fit.proposeDimensions()
  check(
    "fit-proposes-a-geometry",
    proposed ? `${proposed.cols}x${proposed.rows} (term ${term.cols}x${term.rows})` : "no proposal",
    proposed && proposed.cols > 0 && proposed.rows > 0
  )

  // A terminal cannot reflow below ~80 columns, so the pane keeps a floor
  // width and its container scrolls instead (see SessionLive's
  // #terminal-scroller). At the page's `min-w-[640px]` floor the fit addon
  // must still land at or above 80 columns.
  el.style.width = "640px"
  handle.fit.fit()
  check("narrow-floor-is-at-least-80-cols", `cols=${term.cols} at 640px`, term.cols >= 80)
  el.style.width = "800px"
  handle.fit.fit()

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

  return { checks }
}

window.__arbProbe = probe
