#!/usr/bin/env node
//
// bd-9myzv8 — the session dock's terminal, in a real browser against a real
// server, a real `/session` socket and a real reader.
//
// `ArbiterWeb.SessionDockLiveTest` proves the markup: that the expanded window
// hosts the hook and the collapsed ones do not. What it structurally cannot
// prove is everything that only exists on the client — that the hook's
// lifecycle really disposes the xterm and closes the socket on collapse, that
// expanding *resumes* rather than re-snapshots, that a LiveView navigation
// leaves the terminal connected and correctly laid out, and that none of it
// needs a repaint. `Phoenix.LiveViewTest` has no client, no xterm and no
// second socket to lose.
//
//   node scripts/verify_session_dock_terminal.mjs --url http://localhost:4848 \
//     --session-a <uuid> --session-b <uuid> --sync /tmp/dir
//
// `--sync` is a two-file handshake with the Elixir side driving the pane: this
// script writes `<dir>/req` as `<n> <command>`, and
// `ArbiterWeb.SessionDockTerminalBrowserTest` answers in `<dir>/ack` as
// `<n> <result>`. That is how output is produced *while a window is collapsed*
// — the one thing neither side can do alone.
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`. Exit 3 means SKIP (no Chromium).
//
// No npm (RFC §6.1): the browser is one already on the machine and the driver
// is the Chrome DevTools Protocol over Node's built-in `WebSocket` and `fetch`.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const CHROME_CANDIDATES = [
  process.env.ARB_CHROME,
  path.join(process.env.HOME || "", ".cache/ms-playwright/chromium-1234/chrome-linux64/chrome"),
  path.join(
    process.env.HOME || "",
    ".cache/ms-playwright/chromium_headless_shell-1234/chrome-linux64/headless_shell"
  ),
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome"
].filter(Boolean)

const options = parseArgs(process.argv.slice(2))
const BASE = (options.url || "http://localhost:4848").replace(/\/$/, "")
const DEADLINE_MS = Number(options.seconds || 30) * 1000
const SESSION_A = options["session-a"]
const SESSION_B = options["session-b"]
const SYNC = options.sync
const SCREENSHOT = options.screenshot || null

const WIDTH = 1400
const HEIGHT = 900

const BEFORE = "BEFORE-COLLAPSE"
const ACROSS = "ACROSS-THE-NAVIGATION"
const COLLAPSED = "WHILE-COLLAPSED"
const PRESETS = "AT-THE-PRESETS"

const checks = []
const consoleErrors = []

// Declared up here rather than beside `sync()`: the run below is a top-level
// `await`, so anything it touches has to be initialised before it starts.
let syncSeq = 0

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-dock-terminal-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${WIDTH},${HEIGHT}`,
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank"
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
)

let cdp = null
let cdpSessionId = null

try {
  const port = await waitForDevToolsPort(path.join(profile, "DevToolsActivePort"))
  const { webSocketDebuggerUrl } = await (
    await fetch(`http://127.0.0.1:${port}/json/version`)
  ).json()

  cdp = await connect(webSocketDebuggerUrl)

  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" })
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true })

  cdp.on("Runtime.consoleAPICalled", (params) => {
    if (params.type === "error") consoleErrors.push(describeConsole(params))
  })
  cdp.on("Runtime.exceptionThrown", (params) => {
    const d = params.exceptionDetails
    consoleErrors.push((d.exception && d.exception.description) || d.text)
  })

  await cdp.send("Runtime.enable", {}, sessionId)
  await cdp.send("Page.enable", {}, sessionId)

  cdpSessionId = sessionId
  await run(pageDriver(cdp, sessionId))
} catch (error) {
  // The page's own exceptions come with it: a hook that threw in `mounted()`
  // takes every later hook on the page down with it, and the symptom that
  // reaches here is only ever "the terminal never came up".
  const why = (error && error.stack) || String(error)
  const logged = consoleErrors.length ? `\n  page errors: ${JSON.stringify(consoleErrors)}` : ""
  check("harness", false, why + logged)
} finally {
  if (cdp) cdp.close()
  // Exact-PID teardown only. This repo has an incident class around
  // pattern-matching kills reaching the live coordinator.
  browser.kill("SIGTERM")
  await exited(browser)
  try {
    rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 })
  } catch (error) {
    console.log(`NOTE: could not remove ${work}: ${error && error.message}`)
  }
}

const failed = checks.length === 0 || checks.some((c) => !c.ok)
console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- the run ------------------------------------------------------------------

async function run(page) {
  await page.resizeViewport(WIDTH, HEIGHT)
  await page.goto(`${BASE}/`)
  await page.waitForLive()
  await page.poll(`!!document.getElementById("session-dock-root")`, "the dock never rendered")

  // -- expand a window ------------------------------------------------------

  await open(page, SESSION_A)
  const firstGeometry = await mountedGeometry(page, SESSION_A)

  check(
    "expanding-a-window-connects-that-session",
    (await page.eval(`document.querySelectorAll(".xterm").length`)) === 1,
    `${await page.eval(`document.querySelectorAll(".xterm").length`)} xterm(s) in the document`
  )

  // §6.3's floor is 80 columns; anything under it means the window is too
  // narrow to hold a terminal at all, which is exactly what phase 1's
  // 28rem frame would have produced.
  check(
    "the-expanded-window-fits-a-usable-terminal",
    firstGeometry.cols >= 80 && firstGeometry.rows >= 8 && firstGeometry.paneOverflow <= 1,
    JSON.stringify(firstGeometry)
  )

  // The fitted geometry, not xterm's 80x24 default, is what the pane was told.
  check(
    "the-fitted-geometry-reaches-the-pane",
    firstGeometry.meta === `${firstGeometry.cols}x${firstGeometry.rows}`,
    `the strip reports ${firstGeometry.meta}, the terminal is ${firstGeometry.cols}x${firstGeometry.rows}`
  )

  await sync(`emit ${SESSION_A} ${BEFORE}`)
  await waitForText(page, SESSION_A, BEFORE)

  // A stamp no server render and no second `mounted()` can recreate. If it is
  // still here after a navigation, this is literally the same xterm.
  await page.eval(
    `(document.getElementById("session-dock-terminal-${SESSION_A}").__arbStamp = "kept")`
  )

  await screenshot("expanded")

  // -- the headline: navigate with the window open --------------------------

  await page.eval(`document.querySelector('#top-nav a[href="/tasks"]').click()`)
  await page.poll(`location.pathname === "/tasks"`, "the navigation to /tasks never happened")
  await page.waitForLive()
  await page.settle()

  await page.eval(`document.querySelector('#top-nav a[href="/epics"]').click()`)
  await page.poll(`location.pathname === "/epics"`, "the navigation to /epics never happened")
  await page.waitForLive()
  await page.settle()

  const afterNav = await settledGeometry(page, SESSION_A)

  check(
    "navigating-does-not-re-mount-the-terminal",
    afterNav.stamp === "kept" && afterNav.xterms === 1,
    `stamp=${afterNav.stamp} after two live navigations, ${afterNav.xterms} xterm(s)`
  )

  check(
    "navigating-keeps-the-terminal-connected",
    afterNav.state === "live",
    `the strip reads "${afterNav.state}" on ${afterNav.path}`
  )

  check(
    "navigating-keeps-the-geometry-with-no-repaint",
    afterNav.cols === firstGeometry.cols &&
      afterNav.rows === firstGeometry.rows &&
      afterNav.paneOverflow <= 1 &&
      !afterNav.text.includes("reattached"),
    `${firstGeometry.cols}x${firstGeometry.rows} -> ${afterNav.cols}x${afterNav.rows}, ` +
      `overflow=${afterNav.paneOverflow}px, no repaint notice`
  )

  check(
    "navigating-keeps-the-scrollback",
    afterNav.text.includes(BEFORE),
    `the pre-navigation output is still on screen`
  )

  // Still the *same* socket: output produced now arrives without a re-join.
  await sync(`emit ${SESSION_A} ${ACROSS}`)
  await waitForText(page, SESSION_A, ACROSS)

  check(
    "output-keeps-arriving-after-the-navigation",
    true,
    `"${ACROSS}" rendered while on ${afterNav.path}`
  )

  // -- a LiveView rejoin ----------------------------------------------------
  //
  // Dropping the *LiveView* socket is not a navigation: every view rejoins from
  // scratch, the dock included, and the dock's open/expanded state lives in the
  // browser — so the strip is momentarily empty and the terminal element really
  // does go away and come back. The `/session` socket is separate, so nothing
  // about this is lossless by accident: it is the resume book that makes the
  // rebuilt terminal pick up where the old one stopped.
  await page.eval(`
    window.__arbRejoined = false
    window.liveSocket.disconnect(() => {
      window.__arbRejoined = true
      window.liveSocket.connect()
    })
  `)
  await page.poll("window.__arbRejoined === true", "the LiveView socket never dropped")

  const afterRejoin = await mountedGeometry(page, SESSION_A)

  check(
    "a-liveview-rejoin-comes-back-to-a-live-fitted-terminal",
    afterRejoin.state === "live" &&
      afterRejoin.cols === afterNav.cols &&
      afterRejoin.rows === afterNav.rows &&
      afterRejoin.paneOverflow <= 1,
    `rebuilt=${afterRejoin.stamp === null}, ${afterRejoin.cols}x${afterRejoin.rows} ` +
      `(was ${afterNav.cols}x${afterNav.rows}), strip reads "${afterRejoin.state}"`
  )

  // -- one terminal, one socket, whatever is open ---------------------------

  await open(page, SESSION_B)
  await mountedGeometry(page, SESSION_B)

  const bothOpen = await page.json(`(() => ({
    windows: document.querySelectorAll("[id^='session-dock-window-']").length,
    xterms: document.querySelectorAll(".xterm").length,
    a: !!document.getElementById("session-dock-terminal-${SESSION_A}"),
    b: !!document.getElementById("session-dock-terminal-${SESSION_B}")
  }))()`)

  const sockets = await sync(`subscribers ${SESSION_A} ${SESSION_B}`)

  check(
    "at-most-one-xterm-and-one-socket-whatever-is-open",
    bothOpen.windows === 2 && bothOpen.xterms === 1 && !bothOpen.a && bothOpen.b &&
      sockets === "0 1",
    `${bothOpen.windows} windows, ${bothOpen.xterms} xterm, readers attached: ${sockets} (a b)`
  )

  // Back to A. It was collapsed, so this is a fresh xterm resuming.
  await page.eval(`document.getElementById("session-dock-title-${SESSION_A}").click()`)
  await mountedGeometry(page, SESSION_A)

  // -- collapse, produce output, expand ------------------------------------

  await page.eval(`document.getElementById("session-dock-title-${SESSION_A}").click()`)
  await page.poll(
    `!document.getElementById("session-dock-terminal-${SESSION_A}")`,
    "collapsing never removed the terminal"
  )
  await page.settle()

  const collapsed = await page.json(`(() => ({
    xterms: document.querySelectorAll(".xterm").length,
    windows: document.querySelectorAll("[id^='session-dock-window-']").length
  }))()`)

  const afterCollapse = await sync(`subscribers ${SESSION_A} ${SESSION_B}`)

  check(
    "collapsing-tears-down-the-xterm-and-closes-the-socket",
    collapsed.xterms === 0 && collapsed.windows === 2 && afterCollapse === "0 0",
    `${collapsed.windows} collapsed windows hold ${collapsed.xterms} xterms; ` +
      `readers attached: ${afterCollapse} (a b)`
  )

  await sync(`emit ${SESSION_A} ${COLLAPSED}`)

  await page.eval(`document.getElementById("session-dock-title-${SESSION_A}").click()`)
  await waitForText(page, SESSION_A, COLLAPSED)

  const resumed = await mountedGeometry(page, SESSION_A)
  const occurrences = (haystack, needle) => haystack.split(needle).length - 1

  check(
    "expanding-replays-what-the-window-missed-exactly-once",
    occurrences(resumed.text, COLLAPSED) === 1,
    `"${COLLAPSED}" appears ${occurrences(resumed.text, COLLAPSED)} time(s) after the re-expand`
  )

  // Nothing duplicated: the resume starts from the byte offset the previous
  // xterm stopped at, so output it had already rendered is not replayed. A
  // client that re-snapshotted instead would bring the whole ring back.
  check(
    "expanding-resumes-rather-than-replaying-the-whole-stream",
    occurrences(resumed.text, BEFORE) === 0 && occurrences(resumed.text, ACROSS) === 0,
    `the pre-collapse output was not replayed (${BEFORE}: ` +
      `${occurrences(resumed.text, BEFORE)}, ${ACROSS}: ${occurrences(resumed.text, ACROSS)})`
  )

  check(
    "the-resumed-window-is-laid-out-correctly",
    resumed.cols >= 80 && resumed.paneOverflow <= 1 &&
      resumed.meta === `${resumed.cols}x${resumed.rows}`,
    `${resumed.cols}x${resumed.rows}, strip reports ${resumed.meta}, overflow=${resumed.paneOverflow}px`
  )

  // -- a browser resize refits ---------------------------------------------

  await page.resizeViewport(WIDTH, 620)
  await page.settle(600)
  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.rows < ${resumed.rows}
     })()`,
    "a shorter viewport never refit the terminal"
  )

  const resizedGeometry = await settledGeometry(page, SESSION_A)

  check(
    "a-browser-resize-refits-and-tells-the-pane",
    resizedGeometry.rows < resumed.rows &&
      resizedGeometry.meta === `${resizedGeometry.cols}x${resizedGeometry.rows}` &&
      resizedGeometry.paneOverflow <= 1,
    `${resumed.rows} rows -> ${resizedGeometry.rows}, strip reports ${resizedGeometry.meta}`
  )

  await screenshot("resumed")

  // -- a strip layout change refits too -------------------------------------
  //
  // Not the window's height this time: what changes is how much of the strip
  // this window gets, which is what an eighth window — or a narrower browser —
  // does to it. Nothing tells the pane; it has to notice on its own, and §6.3's
  // 80-column floor is where it stops narrowing and starts scrolling instead.
  await page.resizeViewport(900, 620)
  await page.settle(700)

  const squeezed = await settledGeometry(page, SESSION_A)

  check(
    "a-strip-layout-change-refits-the-terminal-down-to-the-80-column-floor",
    squeezed.windowWidth < resizedGeometry.windowWidth &&
      squeezed.cols <= resizedGeometry.cols &&
      squeezed.cols >= 80 &&
      squeezed.paneOverflow <= 1,
    `the window went ${resizedGeometry.windowWidth}px -> ${squeezed.windowWidth}px, the terminal ` +
      `${resizedGeometry.cols} cols -> ${squeezed.cols} (pane reports ${squeezed.meta}), ` +
      `scrolling sideways=${squeezed.scrolls}`
  )

  await page.resizeViewport(WIDTH, HEIGHT)
  await page.settle(700)

  // -- another client resizes the shared pane (bd-4tjw34) -------------------
  //
  // The pane is one tmux pane and the last client to resize it wins, so a
  // second tab — or the operator's own `tmux attach` — leaves this window
  // rendering a screen the pane no longer has. The window has to *adopt* that
  // geometry rather than keep its own, and it must not answer by pushing its
  // own back: two idle clients that both re-assert never stop.
  //
  // The second client is a real one, attached on the Elixir side.

  const mine = await settledGeometry(page, SESSION_A)
  const theirs = { cols: mine.cols + 13, rows: mine.rows + 4 }

  const resized = await sync(`resize ${SESSION_A} ${theirs.cols} ${theirs.rows}`)
  if (resized !== "ok") throw new Error(`the second client could not resize the pane: ${resized}`)

  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.cols === ${theirs.cols} &&
         el.__arbTerminal.term.rows === ${theirs.rows}
     })()`,
    "the window never adopted the geometry the other client gave the pane"
  )

  const adopted = await geometry(page, SESSION_A)

  check(
    "another-clients-resize-is-adopted-by-this-window",
    adopted.cols === theirs.cols &&
      adopted.rows === theirs.rows &&
      adopted.meta === `${theirs.cols}x${theirs.rows}` &&
      adopted.adopted === true,
    `the window was ${mine.cols}x${mine.rows}, the pane went to ${theirs.cols}x${theirs.rows}, ` +
      `the terminal renders ${adopted.cols}x${adopted.rows} and the strip reports ` +
      `${adopted.meta} (adopted=${adopted.adopted})`
  )

  // Idle: long enough for both debounces and a round trip several times over.
  await page.settle(1200)

  const stillTheirs = await geometry(page, SESSION_A)

  check(
    "an-idle-window-never-takes-the-pane-back",
    stillTheirs.cols === theirs.cols &&
      stillTheirs.rows === theirs.rows &&
      stillTheirs.adopted === true,
    `after idling the terminal is ${stillTheirs.cols}x${stillTheirs.rows} ` +
      `and the strip reports ${stillTheirs.meta} (adopted=${stillTheirs.adopted})`
  )

  // ...and interacting takes it back. A keystroke, not a `focus()` call: this
  // window's terminal has held focus since it was expanded, so focusing it
  // again fires no `focusin` at all — and typing into a terminal that is
  // already focused is exactly the case the operator hits.
  await page.type("x")

  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.cols === ${mine.cols} &&
         el.__arbTerminal.term.rows === ${mine.rows}
     })()`,
    "typing never reclaimed the pane at this window's own geometry"
  )

  const reclaimed = await settledGeometry(page, SESSION_A)

  check(
    "interacting-reclaims-the-pane-at-this-windows-own-geometry",
    reclaimed.cols === mine.cols &&
      reclaimed.rows === mine.rows &&
      reclaimed.meta === `${mine.cols}x${mine.rows}` &&
      reclaimed.adopted === false &&
      reclaimed.paneOverflow <= 1,
    `typing put the terminal back to ${reclaimed.cols}x${reclaimed.rows} ` +
      `and the pane reports ${reclaimed.meta} (adopted=${reclaimed.adopted})`
  )

  // -- the size presets (bd-covojz) -----------------------------------------
  //
  // Three discrete geometry changes, each taken through phase 2's one refit
  // path. What has to hold at every one of them: the *same* xterm (the stamp),
  // a pane told the geometry the terminal fitted to, no clipped bottom row,
  // the scrollback still on screen — and, for a side panel, a page that is
  // inset by exactly the panel's width rather than hidden underneath it.

  // A fresh stamp and a fresh marker: the collapse/resume section above
  // deliberately disposed the first xterm and deliberately did *not* replay
  // what came before it, so neither the original stamp nor the original
  // scrollback is a claim about anything here.
  await sync(`emit ${SESSION_A} ${PRESETS}`)
  await waitForText(page, SESSION_A, PRESETS)
  await page.eval(
    `(document.getElementById("session-dock-terminal-${SESSION_A}").__arbStamp = "presets")`
  )

  const compactLayout = await layout(page, SESSION_A)

  await preset(page, SESSION_A, "side")
  const sidePanel = await settledGeometry(page, SESSION_A)
  const sideLayout = await layout(page, SESSION_A)

  check(
    "side-panel-docks-right-at-full-height",
    sideLayout.dockSize === "side" &&
      Math.abs(sideLayout.right - sideLayout.viewportWidth) <= 1 &&
      sideLayout.top <= sideLayout.navHeight + 1 &&
      sideLayout.height > sideLayout.viewportHeight * 0.7,
    `data-dock-size=${sideLayout.dockSize}, right=${sideLayout.right}/${sideLayout.viewportWidth}, ` +
      `top=${sideLayout.top} (nav ${sideLayout.navHeight}), height=${sideLayout.height}`
  )

  // §6.3's floor, in the preset that is most at risk of breaching it.
  check(
    "side-panel-still-fits-eighty-columns",
    sidePanel.cols >= 80 && sidePanel.paneOverflow <= 1 && !sidePanel.scrolls,
    `${sidePanel.cols}x${sidePanel.rows}, overflow=${sidePanel.paneOverflow}px, ` +
      `sideways scroll=${sidePanel.scrolls}`
  )

  check(
    "side-panel-leaves-the-page-usable-beside-it",
    sideLayout.mainInset >= sideLayout.width - 1 &&
      sideLayout.viewportWidth - sideLayout.mainInset >= 480,
    `<main> is inset ${sideLayout.mainInset}px for a ${sideLayout.width}px panel, ` +
      `leaving ${sideLayout.viewportWidth - sideLayout.mainInset}px of page`
  )

  check(
    "side-panel-refits-the-same-terminal",
    sidePanel.stamp === "presets" &&
      sidePanel.xterms === 1 &&
      sidePanel.state === "live" &&
      sidePanel.text.includes(PRESETS),
    `stamp=${sidePanel.stamp}, ${sidePanel.xterms} xterm(s), state=${sidePanel.state}, ` +
      `scrollback kept=${sidePanel.text.includes(PRESETS)}`
  )

  // A browser resize while the panel is up. Below the point where 80 columns
  // and a usable page both fit, the window falls back to Maximized and the
  // title bar says so — and it comes back by itself when the room returns.
  await page.resizeViewport(1000, HEIGHT)
  await page.poll(
    `!!document.getElementById("session-dock-size-fallback-${SESSION_A}")`,
    "a viewport too narrow for a side panel never fell back to Maximized"
  )
  // Maximized at 1000px is wider than the panel was, so this is also the wait
  // for the refit the fallback caused.
  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.cols > ${sidePanel.cols}
     })()`,
    "the fallback to Maximized never refitted the pane"
  )
  const narrow = await settledGeometry(page, SESSION_A)
  const narrowLayout = await layout(page, SESSION_A)

  check(
    "a-viewport-too-narrow-for-a-side-panel-maximizes-and-says-so",
    narrowLayout.dockSize === "max" &&
      narrowLayout.mainInset === 0 &&
      narrow.paneOverflow <= 1 &&
      narrow.stamp === "presets",
    `data-dock-size=${narrowLayout.dockSize}, page inset=${narrowLayout.mainInset}, ` +
      `${narrow.cols}x${narrow.rows}, overflow=${narrow.paneOverflow}px`
  )

  await page.resizeViewport(WIDTH, HEIGHT)
  await page.poll(
    `!document.getElementById("session-dock-size-fallback-${SESSION_A}")`,
    "the side panel never came back when the viewport did"
  )
  // The window re-renders as a panel before the pane has been refitted to it —
  // the refit is two frames and a debounce behind. Wait for the geometry, not
  // just for the markup, or this reads the maximized size it is leaving.
  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.cols === ${sidePanel.cols}
     })()`,
    "the side panel never refitted back to its own geometry"
  )
  const widened = await settledGeometry(page, SESSION_A)

  check(
    "a-browser-resize-under-a-side-panel-refits-the-pane",
    widened.cols === sidePanel.cols &&
      widened.rows === sidePanel.rows &&
      widened.meta === `${widened.cols}x${widened.rows}` &&
      widened.paneOverflow <= 1,
    `back to ${widened.cols}x${widened.rows}, pane reports ${widened.meta}`
  )

  await screenshot("side-panel")

  await preset(page, SESSION_A, "max")
  const maximized = await settledGeometry(page, SESSION_A)
  const maxLayout = await layout(page, SESSION_A)

  check(
    "maximized-fills-nearly-the-whole-page",
    maxLayout.dockSize === "max" &&
      maxLayout.width >= maxLayout.viewportWidth * 0.9 &&
      maxLayout.mainInset === 0 &&
      maximized.cols > sidePanel.cols &&
      maximized.paneOverflow <= 1,
    `${maxLayout.width}px of ${maxLayout.viewportWidth}, ${maximized.cols}x${maximized.rows}, ` +
      `overflow=${maximized.paneOverflow}px`
  )

  // "Reachable" has to mean *clickable*, not "has a rectangle": a Maximized
  // window is `fixed` and opaque, and the roster's panel opens upward into
  // exactly the band it covers. So this opens the roster and hit-tests it —
  // `elementFromPoint` at the panel's centre has to land inside the panel, not
  // on the window painted over it.
  const rosterHit = await rosterHitTest(page)

  check(
    "maximized-keeps-the-roster-reachable",
    maxLayout.rosterVisible && rosterHit.panelOnTop && rosterHit.toggleOnTop,
    `toggle ${maxLayout.rosterVisible ? "" : "off-screen, "}hit ` +
      `#${rosterHit.atPanelCentre || "nothing"} at the panel's centre and ` +
      `#${rosterHit.atToggleCentre || "nothing"} on the toggle`
  )

  await screenshot("maximized-roster")

  // Back to just the window for the screenshot and for what follows.
  await page.eval(`document.getElementById("session-dock-roster-toggle").click()`)
  await page.poll(
    `!document.getElementById("session-dock-roster-panel")`,
    "the roster never closed again"
  )

  await screenshot("maximized")

  await preset(page, SESSION_A, "compact")
  await page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${SESSION_A}")
       return el && el.__arbTerminal && el.__arbTerminal.term.cols === ${compactLayout.cols}
     })()`,
    "Compact never refitted back to the geometry it started at"
  )
  const backToCompact = await settledGeometry(page, SESSION_A)
  const compactAgain = await layout(page, SESSION_A)

  check(
    "compact-comes-back-exactly-as-it-was",
    compactAgain.dockSize === "compact" &&
      compactAgain.mainInset === 0 &&
      backToCompact.cols === compactLayout.cols &&
      backToCompact.rows === compactLayout.rows &&
      backToCompact.stamp === "presets" &&
      backToCompact.text.includes(PRESETS) &&
      backToCompact.paneOverflow <= 1,
    `${compactLayout.cols}x${compactLayout.rows} -> ${backToCompact.cols}x${backToCompact.rows} ` +
      `across three presets, same xterm=${backToCompact.stamp === "presets"}`
  )

  // -- the keyboard rule ----------------------------------------------------

  const focus = await page.json(`(() => {
    const el = document.getElementById("session-dock-terminal-${SESSION_A}")
    el.__arbTerminal.focus()
    return { inTerminal: el.contains(document.activeElement) }
  })()`)

  await page.key("Escape", { ctrl: true, shift: true })
  await page.settle(150)

  const released = await page.json(`(() => {
    const el = document.getElementById("session-dock-terminal-${SESSION_A}")
    return {
      inTerminal: el.contains(document.activeElement),
      onTitle: document.activeElement === document.getElementById("session-dock-title-${SESSION_A}")
    }
  })()`)

  check(
    "ctrl-shift-escape-hands-the-keyboard-back-to-the-page",
    focus.inTerminal && !released.inTerminal && released.onTitle,
    `focused in the terminal=${focus.inTerminal}, then on the title bar=${released.onTitle}`
  )

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )
}

// -- page helpers -------------------------------------------------------------

// Pick a size preset from the expanded window's title bar and wait for the
// server's re-render to land. The refit that follows it is deliberately *not*
// waited for here — `settledGeometry` is what proves it happened.
async function preset(page, id, size) {
  await page.eval(`document.getElementById("session-dock-size-${size}-${id}").click()`)
  await page.poll(
    `document.getElementById("session-dock-size-${size}-${id}").getAttribute("aria-pressed") === "true"`,
    `the ${size} preset never took for ${id}`
  )
  await page.settle()
}

// Where the window actually is, and what the *page* gave up for it. The
// terminal's own geometry is `geometry/2`'s job; this is the other half of the
// side panel's contract — the page has to stay visible and usable beside it.
function layout(page, id) {
  return page.json(`(() => {
    const win = document.getElementById("session-dock-window-${id}")
    const rect = win ? win.getBoundingClientRect() : null
    const main = document.querySelector("main")
    const nav = document.getElementById("top-nav")
    const roster = document.getElementById("session-dock-roster-toggle")
    const rosterRect = roster ? roster.getBoundingClientRect() : null
    const term = document.getElementById("session-dock-terminal-${id}")
    const xterm = term && term.__arbTerminal ? term.__arbTerminal.term : null

    return {
      dockSize: document.documentElement.dataset.dockSize || null,
      top: rect ? Math.round(rect.top) : null,
      right: rect ? Math.round(rect.right) : null,
      width: rect ? Math.round(rect.width) : null,
      height: rect ? Math.round(rect.height) : null,
      navHeight: nav ? Math.round(nav.getBoundingClientRect().height) : null,
      mainInset: main ? Math.round(parseFloat(getComputedStyle(main).paddingRight)) : null,
      rosterVisible:
        !!rosterRect &&
        rosterRect.width > 0 &&
        rosterRect.right <= window.innerWidth &&
        rosterRect.bottom <= window.innerHeight,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      cols: xterm ? xterm.cols : null,
      rows: xterm ? xterm.rows : null
    }
  })()`)
}

// Acceptance 6's other half: with a Maximized window on screen, does clicking
// the roster toggle actually show a roster? The window is `fixed` with no
// z-index of its own, which still paints it over anything in-flow in the dock
// root — so the answer is a hit test at the panel's centre rather than a
// bounding box, which an element painted *behind* another one still has.
async function rosterHitTest(page) {
  await page.eval(`(() => {
    if (!document.getElementById("session-dock-roster-panel")) {
      document.getElementById("session-dock-roster-toggle").click()
    }
  })()`)
  await page.poll(
    `!!document.getElementById("session-dock-roster-panel")`,
    "the roster never opened under a Maximized window"
  )

  return page.json(`(() => {
    const topmost = (rect) => {
      const el = document.elementFromPoint(
        Math.round(rect.left + rect.width / 2),
        Math.round(rect.top + rect.height / 2)
      )
      return el ? el.closest("[id]") : null
    }

    const panel = document.getElementById("session-dock-roster-panel")
    const toggle = document.getElementById("session-dock-roster-toggle")
    const atPanel = panel ? topmost(panel.getBoundingClientRect()) : null
    const atToggle = toggle ? topmost(toggle.getBoundingClientRect()) : null

    return {
      atPanelCentre: atPanel ? atPanel.id : null,
      atToggleCentre: atToggle ? atToggle.id : null,
      panelOnTop: !!atPanel && !!panel && (atPanel === panel || panel.contains(atPanel)),
      toggleOnTop: !!atToggle && !!toggle && (atToggle === toggle || toggle.contains(atToggle))
    }
  })()`)
}

async function open(page, id) {
  await page.eval(`(() => {
    if (!document.getElementById("session-dock-roster-panel")) {
      document.getElementById("session-dock-roster-toggle").click()
    }
  })()`)
  await page.poll(`!!document.getElementById("session-dock-open-${id}")`, `no roster row for ${id}`)
  await page.eval(`document.getElementById("session-dock-open-${id}").click()`)
  await page.poll(
    `!!document.getElementById("session-dock-terminal-${id}")`,
    `the window for ${id} never expanded a terminal`
  )
}

// A terminal that has *just been built* — on expand, on a rejoin — has one
// more geometry change coming that has nothing to do with what is being
// measured: xterm measures its cell inside `open()`, and the hook re-measures
// and refits once the dashboard's mono **webfont** has resolved. Reading
// across that correction would make every "the geometry did not change" claim
// below a measurement of the font swap.
async function mountedGeometry(page, id) {
  await waitLive(page, id)
  await page.eval(`document.fonts.ready`, true)
  await page.settle(500)

  return settledGeometry(page, id)
}

async function waitLive(page, id) {
  try {
    await page.poll(
      `document.getElementById("session-dock-status-${id}").dataset.state === "live"`,
      `the terminal for ${id} never reached "live"`
    )
  } catch (error) {
    // "It never came up" is the least useful sentence a browser check can end
    // on. Say what the page actually had when the deadline ran out.
    const state = await page.json(`(() => {
      const status = document.getElementById("session-dock-status-${id}")
      const el = document.getElementById("session-dock-terminal-${id}")
      const term = el && el.__arbTerminal ? el.__arbTerminal : null
      return {
        status: status ? status.dataset.state || null : "no status strip",
        statusText: status ? status.textContent.trim() : null,
        pane: !!el,
        handle: !!term,
        xterms: document.querySelectorAll(".xterm").length,
        socket: term && term.stream ? term.stream.state || null : null,
        lastSeq: term && term.stream ? term.stream.lastSeq : null,
        stalled: !!document.getElementById("session-dock-stalled-${id}"),
        unavailable: !!document.getElementById("session-dock-unavailable-${id}"),
        remote: !!document.getElementById("session-dock-remote-${id}"),
        liveSocket: !!(window.liveSocket && window.liveSocket.isConnected())
      }
    })()`)

    throw new Error(`${error.message} — page state: ${JSON.stringify(state)}`)
  }
}

// The fit reaches the pane through two debounces in series — a drag must not
// re-lay-out the pane for every attached client on every frame — and the
// `meta` that comes back is the server's own word for the geometry it now
// has. So "the fitted cols/rows are sent to the pane" is a claim about where
// this settles, not about the same tick; anything else would be testing the
// debounce away.
async function settledGeometry(page, id) {
  const deadline = Date.now() + DEADLINE_MS
  let last = null

  // One read, not a poll followed by a read: the fit and the `meta` that
  // answers it are two round trips, and a snapshot taken across them can
  // catch a geometry the pane has not caught up with — which is the same
  // thing a real failure looks like. Re-read until a *single* read agrees.
  while (Date.now() < deadline) {
    last = await geometry(page, id)
    if (last.meta === `${last.cols}x${last.rows}`) return last
    await sleep(100)
  }

  throw new Error(
    `the pane for ${id} was never told the geometry the terminal fitted to ` +
      `(terminal ${last && last.cols}x${last && last.rows}, pane ${last && last.meta})`
  )
}

function waitForText(page, id, needle) {
  return page.poll(
    `(() => {
       const el = document.getElementById("session-dock-terminal-${id}")
       if (!el || !el.__arbTerminal) return false
       const b = el.__arbTerminal.term.buffer.active
       for (let i = 0; i < b.length; i++) {
         const line = b.getLine(i)
         if (line && line.translateToString(true).includes(${JSON.stringify(needle)})) return true
       }
       return false
     })()`,
    `"${needle}" never rendered in ${id}`
  )
}

// Everything worth asserting about the pane, read through the handle the hook
// exposes on the element — the canvas renderer draws pixels, so there is no
// DOM text to read instead.
function geometry(page, id) {
  return page.json(`(() => {
    const el = document.getElementById("session-dock-terminal-${id}")
    const status = document.getElementById("session-dock-status-${id}")
    const term = el && el.__arbTerminal ? el.__arbTerminal.term : null
    const screen = el ? el.querySelector(".xterm-screen") : null
    const style = el ? getComputedStyle(el) : null

    const lines = []
    if (term) {
      const b = term.buffer.active
      for (let i = 0; i < b.length; i++) {
        const line = b.getLine(i)
        lines.push(line ? line.translateToString(true) : "")
      }
    }

    // How far the rendered screen spills out of the pane's content box. One
    // row of overflow is exactly the bd-3r2otb clipping bug.
    const overflow =
      screen && el
        ? Math.round(
            screen.getBoundingClientRect().bottom -
              (el.getBoundingClientRect().bottom - parseFloat(style.paddingBottom))
          )
        : null

    const scroller = document.getElementById("session-dock-scroller-${id}")
    const win = document.getElementById("session-dock-window-${id}")

    // The size label reads "120x40", or "adopted 120x40" for a pane sitting at
    // another client's geometry (bd-4tjw34), either of them optionally
    // followed by " . N clients". The geometry token and the adopted flag are
    // reported apart so a caller can assert on one without the other.
    // (No backticks in here: this whole function is inside a template literal.)
    const metaSlot = status ? status.querySelector('[data-role="meta"]') : null
    const metaWords = metaSlot ? metaSlot.textContent.split(" ") : []

    return {
      cols: term ? term.cols : null,
      rows: term ? term.rows : null,
      windowWidth: win ? Math.round(win.getBoundingClientRect().width) : null,
      scrolls: scroller ? scroller.scrollWidth > scroller.clientWidth + 1 : null,
      xterms: document.querySelectorAll(".xterm").length,
      stamp: el ? el.__arbStamp || null : null,
      state: status ? status.dataset.state : null,
      meta: metaSlot ? metaWords.find((w) => /^\\d+x\\d+$/.test(w)) || metaWords[0] : null,
      adopted: metaSlot ? metaSlot.dataset.adopted === "true" : null,
      paneOverflow: overflow,
      text: lines.join("\\n"),
      path: location.pathname
    }
  })()`)
}

async function screenshot(label) {
  if (!SCREENSHOT) return

  const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, cdpSessionId)
  const target = SCREENSHOT.replace(/(\.png)?$/, `-${label}.png`)
  writeFileSync(target, Buffer.from(data, "base64"))
  console.log(`SCREENSHOT ${target}`)
}

// -- the handshake with the Elixir side ---------------------------------------
//
// Producing output *while a window is collapsed*, and counting the readers
// actually attached to a session, are both things only the server can do — and
// both are exactly what this phase has to prove. So the two processes take
// turns over two files.

async function sync(command) {
  if (!SYNC) throw new Error("--sync is required")

  const n = ++syncSeq
  writeFileSync(path.join(SYNC, "req"), `${n} ${command}`)

  const deadline = Date.now() + DEADLINE_MS
  const ack = path.join(SYNC, "ack")

  while (Date.now() < deadline) {
    if (existsSync(ack)) {
      const [seq, ...rest] = readFileSync(ack, "utf8").trim().split(" ")
      if (Number(seq) === n) return rest.join(" ")
    }
    await sleep(50)
  }

  throw new Error(`the Elixir side never answered "${command}"`)
}

// -- the page driver ----------------------------------------------------------

function pageDriver(cdp, sessionId) {
  const driver = {
    async goto(url) {
      await cdp.send("Page.navigate", { url }, sessionId)
      await driver.poll(`document.readyState === "complete"`, `${url} never finished loading`)
    },

    waitForLive() {
      return driver.poll(
        `(() => {
           if (!window.liveSocket || !window.liveSocket.isConnected()) return false
           const main = document.querySelector("[data-phx-main]")
           return !!main && main.classList.contains("phx-connected")
         })()`,
        "the LiveView never joined"
      )
    },

    async eval(expression, awaitPromise = false) {
      const { result, exceptionDetails } = await cdp.send(
        "Runtime.evaluate",
        { expression, returnByValue: true, awaitPromise, userGesture: true },
        sessionId
      )

      if (exceptionDetails) {
        throw new Error(
          (exceptionDetails.exception && exceptionDetails.exception.description) ||
            exceptionDetails.text
        )
      }

      return result.value
    },

    async json(expression) {
      return JSON.parse(await driver.eval(`JSON.stringify(${expression})`))
    },

    // A *trusted* key event, which a synthetic `dispatchEvent` is not: only a
    // trusted one can be cancelled by `preventDefault`, and the whole claim
    // here is that `Ctrl+Shift+Escape` never reaches the agent.
    // A printable keystroke on whatever holds focus. `key` below is Escape and
    // only Escape (it hard-codes the virtual key code); this is the ordinary
    // typing path, which is what reclaims a pane another client took
    // (bd-4tjw34).
    async type(text) {
      const code = text.toUpperCase().charCodeAt(0)
      const common = {
        key: text,
        code: `Key${text.toUpperCase()}`,
        text,
        unmodifiedText: text,
        windowsVirtualKeyCode: code,
        nativeVirtualKeyCode: code
      }

      await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", ...common }, sessionId)
      await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...common }, sessionId)
    },

    async key(key, { ctrl = false, shift = false } = {}) {
      const modifiers = (ctrl ? 2 : 0) | (shift ? 8 : 0)
      const common = { key, code: key, windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27, modifiers }

      await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", ...common }, sessionId)
      await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...common }, sessionId)
    },

    async poll(expression, message) {
      await driver.pollValue(`(${expression}) || null`, message)
    },

    async pollValue(expression, message) {
      const deadline = Date.now() + DEADLINE_MS

      while (Date.now() < deadline) {
        let value = null
        try {
          value = await driver.eval(expression)
        } catch (_error) {
          // A navigation can tear the execution context out from under an
          // evaluate; the next poll runs in the new one.
        }
        if (value !== null && value !== undefined && value !== false) return value
        await sleep(100)
      }

      throw new Error(message)
    },

    settle(ms = 400) {
      return sleep(ms)
    },

    async resizeViewport(width, height) {
      await cdp.send(
        "Emulation.setDeviceMetricsOverride",
        { width, height, deviceScaleFactor: 1, mobile: false },
        sessionId
      )
    }
  }

  return driver
}

// -- helpers ------------------------------------------------------------------

function parseArgs(argv) {
  const options = {}
  for (let i = 0; i < argv.length; i += 2) {
    options[argv[i].replace(/^--/, "")] = argv[i + 1]
  }
  return options
}

function firstExisting(candidates, what) {
  const found = candidates.find((c) => existsSync(c))
  if (!found) {
    console.log(`RESULT: SKIP — no ${what} found (looked in ${candidates.join(", ")})`)
    process.exit(3)
  }
  return found
}

function describeConsole(params) {
  return (params.args || [])
    .map((a) => a.description || (a.value !== undefined ? String(a.value) : a.type))
    .join(" ")
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function exited(child, graceMs = 5000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve()

  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      resolve()
    }, graceMs)
    child.once("exit", done)
  })
}

async function waitForDevToolsPort(file) {
  for (let i = 0; i < 100; i++) {
    if (existsSync(file)) {
      const port = readFileSync(file, "utf8").split("\n")[0].trim()
      if (port) return port
    }
    await sleep(100)
  }
  throw new Error("the browser never wrote a DevToolsActivePort")
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    const pending = new Map()
    const listeners = new Map()
    let nextId = 0

    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data)

      if (message.method) {
        const handler = listeners.get(message.method)
        if (handler) handler(message.params || {})
        return
      }

      const waiter = pending.get(message.id)
      if (!waiter) return
      pending.delete(message.id)
      message.error
        ? waiter.reject(new Error(JSON.stringify(message.error)))
        : waiter.resolve(message.result)
    })

    ws.addEventListener("error", () => reject(new Error("devtools socket error")))

    ws.addEventListener("open", () =>
      resolve({
        send(method, params = {}, sessionId) {
          const id = ++nextId
          const frame = { id, method, params }
          if (sessionId) frame.sessionId = sessionId
          ws.send(JSON.stringify(frame))
          return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }))
        },
        on(method, handler) {
          listeners.set(method, handler)
        },
        close: () => ws.close()
      })
    )
  })
}
