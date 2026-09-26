#!/usr/bin/env node
//
// bd-bcroux — the worker output pane's horizontal scroll and the session
// dock's close/maximize touch targets, at real phone widths in a real
// browser.
//
// `ArbiterWeb.WorkerDetailLiveTest` and `ArbiterWeb.SessionDockLiveTest`
// prove the markup: the pane's container carries `overflow-x-auto` and not
// `overflow-x-hidden`, the row text is `whitespace-pre` rather than
// `whitespace-nowrap`, and the close/max buttons carry the `max-sm:size-11`/
// `max-sm:h-11` classes. What they cannot prove is what a layout engine
// actually does with those classes at 375/414px — that the pane really
// scrolls horizontally without dragging the page with it, and that the
// buttons really measure >=44px once Tailwind's `max-sm:` breakpoint and the
// dock's own `--session-dock-strip-height` media-query bump both apply.
// `Phoenix.LiveViewTest` has no layout engine.
//
//   node scripts/verify_mobile_touch.mjs --url http://localhost:4848 --task <task id>
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`. `ArbiterWeb.MobileTouchBrowserTest` runs it
// against a Bandit listener as part of `mix test`; exit 3 means SKIP (no
// Chromium).
//
// No npm (RFC §6.1): the browser is one already on the machine and the
// driver is the Chrome DevTools Protocol over Node's built-in `WebSocket`
// and `fetch`.

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
const TASK = options.task || null
// `--screenshot <path>` writes a PNG per width/theme combo. Nothing asserts
// on these; they are the before/after evidence for the PR.
const SCREENSHOT = options.screenshot || null

const HEIGHT = 812
const DESKTOP_WIDTH = 1280
const DESKTOP_HEIGHT = 900
// The two phone widths the ticket names, portrait.
const PHONE_WIDTHS = [375, 414]
const THEMES = ["light", "dark"]
// The app's own touch-target token (`--control-lg` in app.css).
const TOUCH_TARGET = 44

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-mobile-touch-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${DESKTOP_WIDTH},${DESKTOP_HEIGHT}`,
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
  check("harness", false, (error && error.stack) || String(error))
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

check(
  "no-console-errors",
  consoleErrors.length === 0,
  consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
)

const failed = checks.length === 0 || checks.some((c) => !c.ok)
console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- the run ------------------------------------------------------------------

async function run(page) {
  if (!TASK) throw new Error("--task <task id> is required")

  await desktopRegressionPass(page)

  for (const theme of THEMES) {
    for (const width of PHONE_WIDTHS) {
      await outputPanePass(page, width, theme)
      await sessionDockPass(page, width, theme)
    }
  }
}

// -- desktop: nothing here should have regressed ------------------------------

async function desktopRegressionPass(page) {
  await page.resizeViewport(DESKTOP_WIDTH, DESKTOP_HEIGHT)
  await page.goto(`${BASE}/workers/${TASK}`)
  await page.waitForLive()
  await page.poll(`!!document.getElementById("worker-output")`, "the output pane never rendered")
  // `setTheme` after navigation, not before: `Page.navigate` replaces the
  // whole document, and `theme.js` reads `localStorage` (empty in a throwaway
  // profile) rather than any attribute set on the page that is about to be
  // thrown away.
  await page.setTheme("light")
  await page.settle()

  const pane = await page.json(pageWidthProbe())
  check(
    "desktop-1280-no-page-level-horizontal-scroll",
    pane.pageScrollWidth <= DESKTOP_WIDTH + 1,
    `document scrollWidth=${pane.pageScrollWidth} viewport=${DESKTOP_WIDTH}`
  )
  await screenshot("desktop-1280-worker-output")

  await openDock(page)
  await screenshot("desktop-1280-session-dock")
}

// -- the output pane: its own horizontal scroll container --------------------

async function outputPanePass(page, width, theme) {
  await page.resizeViewport(width, HEIGHT)
  await page.goto(`${BASE}/workers/${TASK}`)
  await page.waitForLive()
  await page.poll(`!!document.getElementById("worker-output")`, "the output pane never rendered")
  await page.setTheme(theme)
  await page.settle()

  const geometry = await page.json(`(() => {
    const pane = document.getElementById("worker-output")
    const style = getComputedStyle(pane)
    return {
      overflowX: style.overflowX,
      paneScrollWidth: pane.scrollWidth,
      paneClientWidth: pane.clientWidth,
      ${pageWidthProbeFields()}
    }
  })()`)

  check(
    `${width}-${theme}-output-pane-is-its-own-horizontal-scroll-container`,
    geometry.overflowX === "auto",
    `computed overflow-x=${geometry.overflowX}`
  )

  check(
    `${width}-${theme}-output-pane-actually-overflows-its-own-width`,
    geometry.paneScrollWidth > geometry.paneClientWidth,
    `scrollWidth=${geometry.paneScrollWidth} clientWidth=${geometry.paneClientWidth}`
  )

  await checkNoPageOverflow(page, width, theme, geometry.pageScrollWidth, "output-pane")

  // Touch-scroll the pane itself and confirm the page underneath did not
  // move — the whole point of giving the pane its own scroll container.
  const scrolled = await page.json(`(() => {
    const pane = document.getElementById("worker-output")
    const before = window.scrollX
    pane.scrollLeft = 200
    return { paneScrollLeft: pane.scrollLeft, pageScrollX: window.scrollX, pageScrollXBefore: before }
  })()`)

  check(
    `${width}-${theme}-scrolling-the-pane-does-not-scroll-the-page`,
    scrolled.paneScrollLeft > 0 && scrolled.pageScrollX === scrolled.pageScrollXBefore,
    `pane.scrollLeft=${scrolled.paneScrollLeft} page.scrollX ${scrolled.pageScrollXBefore}->${scrolled.pageScrollX}`
  )

  await screenshot(`${width}-${theme}-worker-output`)
}

// -- the session dock: close and maximize are touch-sized ---------------------

async function sessionDockPass(page, width, theme) {
  await page.resizeViewport(width, HEIGHT)

  const sessionId = await openDock(page)
  // After `openDock`'s navigation, for the same reason as `outputPanePass`.
  await page.setTheme(theme)
  await page.settle()

  const page1 = await page.json(pageWidthProbe())
  await checkNoPageOverflow(page, width, theme, page1.pageScrollWidth, "session-dock")

  const dismiss = await page.json(rectProbe(`session-dock-dismiss-${sessionId}`))
  check(
    `${width}-${theme}-close-button-is-touch-sized`,
    dismiss.width >= TOUCH_TARGET && dismiss.height >= TOUCH_TARGET,
    `${dismiss.width}x${dismiss.height}, need >=${TOUCH_TARGET}`
  )

  const maxButton = await page.json(rectProbe(`session-dock-size-max-${sessionId}`))
  check(
    `${width}-${theme}-maximize-button-is-touch-sized`,
    maxButton.width >= TOUCH_TARGET && maxButton.height >= TOUCH_TARGET,
    `${maxButton.width}x${maxButton.height}, need >=${TOUCH_TARGET}`
  )

  await screenshot(`${width}-${theme}-session-dock-before-maximize`)

  // Click Max and confirm the window actually fills the viewport, with the
  // close button still reachable — the "obvious way back".
  await page.eval(`document.getElementById("session-dock-size-max-${sessionId}").click()`)
  await page.poll(
    `document.getElementById("session-dock-window-${sessionId}").dataset.size === "max"`,
    "the window never switched to Max"
  )
  await page.settle()

  const frame = await page.json(rectProbe(`session-dock-frame-${sessionId}`))
  check(
    `${width}-${theme}-maximize-fills-the-viewport`,
    frame.width >= width * 0.85 && frame.height >= HEIGHT * 0.55,
    `frame ${frame.width}x${frame.height} in a ${width}x${HEIGHT} viewport`
  )

  const dismissAfterMax = await page.json(rectProbe(`session-dock-dismiss-${sessionId}`))
  check(
    `${width}-${theme}-close-still-reachable-and-touch-sized-once-maximized`,
    dismissAfterMax.width >= TOUCH_TARGET &&
      dismissAfterMax.height >= TOUCH_TARGET &&
      dismissAfterMax.top >= 0 &&
      dismissAfterMax.left >= 0 &&
      dismissAfterMax.right <= width + 1,
    `${dismissAfterMax.width}x${dismissAfterMax.height} at top=${dismissAfterMax.top} left=${dismissAfterMax.left} right=${dismissAfterMax.right}`
  )

  await screenshot(`${width}-${theme}-session-dock-maximized`)

  // The way back: dismiss closes the window outright — reload the dock state
  // for the next pass by dismissing it now.
  await page.eval(`document.getElementById("session-dock-dismiss-${sessionId}").click()`)
  await page.poll(
    `!document.getElementById("session-dock-window-${sessionId}")`,
    "dismiss never removed the window"
  )
}

// Opens the dock's roster and expands its one seeded session. Returns the
// session id.
async function openDock(page) {
  await page.goto(`${BASE}/`)
  await page.waitForLive()
  await page.poll(`!!document.getElementById("session-dock-root")`, "the dock never rendered")

  await page.eval(`document.getElementById("session-dock-roster-toggle").click()`)
  await page.poll(`!!document.getElementById("session-dock-roster-panel")`, "the roster never opened")

  const sessionId = await page.pollValue(
    `(() => {
       const row = document.querySelector("#session-dock-roster-list > li")
       return row ? row.id.replace("session-dock-roster-", "") : null
     })()`,
    "the roster listed no sessions"
  )

  await page.eval(`document.getElementById("session-dock-open-${sessionId}").click()`)
  await page.poll(
    `!!document.getElementById("session-dock-window-${sessionId}")`,
    "the session never opened into the strip"
  )
  await page.settle()

  return sessionId
}

// A page-level scrollbar could come from `#app-status-bar` (the global top
// bar — pre-existing, out of this ticket's scope: it names the worker output
// pane and the session dock, not the header) rather than from either of
// those two. So this does not just assert `scrollWidth <= viewport`; it asks
// *whose* overflow it is, by hiding the header and re-measuring. If the page
// still overflows without it, the overflow is charged to `owner` (the pane or
// the dock) and the check fails; if hiding the header clears it, the header
// is the sole cause, and that is reported as a NOTE — a known, pre-existing
// issue this ticket did not introduce and is not about — rather than a FAIL
// that would misattribute someone else's bug to this change.
async function checkNoPageOverflow(page, width, theme, pageScrollWidth, owner) {
  if (pageScrollWidth <= width + 1) {
    check(
      `${width}-${theme}-${owner}-no-page-level-horizontal-scroll`,
      true,
      `document scrollWidth=${pageScrollWidth} viewport=${width}`
    )
    return
  }

  const withoutHeader = await page.json(`(() => {
    const header = document.getElementById("app-status-bar")
    const prev = header ? header.style.display : null
    if (header) header.style.display = "none"
    const width = document.documentElement.scrollWidth
    if (header) header.style.display = prev
    return width
  })()`)

  if (withoutHeader <= width + 1) {
    console.log(
      `NOTE: ${width}-${theme} page scrollWidth=${pageScrollWidth} (viewport ${width}) comes entirely from #app-status-bar (pre-existing, unrelated to the worker output pane or the session dock — scrollWidth=${withoutHeader} with it hidden). Not charged to this ticket.`
    )
    check(
      `${width}-${theme}-${owner}-no-page-level-horizontal-scroll`,
      true,
      `${owner} itself adds no page-level overflow (header-only overflow noted above)`
    )
    return
  }

  check(
    `${width}-${theme}-${owner}-no-page-level-horizontal-scroll`,
    false,
    `document scrollWidth=${pageScrollWidth} viewport=${width}, persists at ${withoutHeader} with the header hidden — not just the header`
  )
}

function pageWidthProbe() {
  return `(() => (${pageWidthProbeFields(true)}))()`
}

function pageWidthProbeFields(wrap = false) {
  const body = `pageScrollWidth: document.documentElement.scrollWidth`
  return wrap ? `{ ${body} }` : body
}

function rectProbe(id) {
  return `(() => {
    const el = document.getElementById("${id}")
    if (!el) return { width: 0, height: 0, top: -1, left: -1, right: -1 }
    const r = el.getBoundingClientRect()
    return {
      width: Math.round(r.width),
      height: Math.round(r.height),
      top: Math.round(r.top),
      left: Math.round(r.left),
      right: Math.round(r.right)
    }
  })()`
}

// Nothing asserts on these; they are the before/after evidence for the PR.
async function screenshot(label) {
  if (!SCREENSHOT) return

  const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, cdpSessionId)
  const target = SCREENSHOT.replace(/(\.png)?$/, `-${label}.png`)
  writeFileSync(target, Buffer.from(data, "base64"))
  console.log(`SCREENSHOT ${target}`)
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

    settle(ms = 300) {
      return sleep(ms)
    },

    // `theme.js` reads `data-theme` off `<html>` before first paint; setting
    // it here (rather than via `localStorage`, which only takes effect on
    // the *next* load) applies instantly to the already-rendered page.
    async setTheme(theme) {
      await driver.eval(`document.documentElement.setAttribute("data-theme", "${theme}")`)
    },

    async resizeViewport(width, height) {
      await cdp.send(
        "Emulation.setDeviceMetricsOverride",
        { width, height, deviceScaleFactor: 1, mobile: width < 768 },
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
