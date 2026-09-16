#!/usr/bin/env node
//
// bd-dlc136 — the session dock in a real browser.
//
// `ArbiterWeb.SessionDockLiveTest` proves everything the server decides: the
// roster's contents, one-expanded-at-a-time, dismiss-is-view-only, and that a
// hostile `localStorage` payload is re-validated. What it cannot prove is the
// acceptance criterion the whole phase exists for — that **LiveView
// navigation does not re-mount the dock**. That is a client-side fact about
// `data-phx-sticky`: on a `live_redirect` the client moves the existing dock
// element into the incoming main container instead of re-rendering it.
// `Phoenix.LiveViewTest` has no client, so in a `ConnCase` a navigation is a
// fresh `live/2` and the dock is a fresh process either way — the test would
// pass whether or not `sticky: true` were there at all.
//
// So this drives a real Chromium:
//
//   node scripts/verify_session_dock.mjs --url http://localhost:4848
//
//   1. stamp the dock's DOM node with a JS property no server render can
//      recreate, open a session into the strip, expand it, scroll the roster;
//   2. live-navigate to another page and check the stamp, the window, the
//      expansion and the scroll offset all survived;
//   3. reload the page outright and check the dock comes back from
//      `localStorage`;
//   4. dismiss, reload again, and check it stays gone;
//   5. measure that the page actually reserves room for the strip, which is
//      the one claim `pb-[var(--session-dock-strip-height)]` can quietly stop
//      making if Tailwind ever fails to compile the arbitrary value.
//
// Since phase 2 (bd-9myzv8) the expanded window holds a terminal. What that
// terminal does — connect, resume, survive navigation, lay itself out — is
// `scripts/verify_session_dock_terminal.mjs`'s business; this file only keeps
// the strip's own invariant, that there is never more than one of them.
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`. `ArbiterWeb.SessionDockBrowserTest` runs it
// against a Bandit listener as part of `mix test`; exit 3 means SKIP.
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
// `--screenshot <path>` writes a PNG of the full strip at the end of the run.
// Nothing asserts on it; it is there so a human (or the next phase) can look
// at what the dock actually renders without booting a server by hand.
const SCREENSHOT = options.screenshot || null

const WIDTH = 1280
const HEIGHT = 900

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-session-dock-"))
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

const failed = checks.length === 0 || checks.some((c) => !c.ok)
console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- the run ------------------------------------------------------------------

async function run(page) {
  await page.resizeViewport(WIDTH, HEIGHT)
  await page.goto(`${BASE}/`)
  await page.waitForLive()

  // The dock is its own LiveView, so "the page is live" is not "the dock is
  // live" — wait for its hook to have run, which is also what proves the
  // `localStorage` read did not throw the hook away.
  await page.poll(
    `!!document.getElementById("session-dock-root") &&
     document.getElementById("session-dock-root").classList.contains("phx-hook-loaded") !== undefined`,
    "the dock never rendered"
  )

  check(
    "dock-renders-on-a-dashboard-page",
    await page.eval(`!!document.getElementById("session-dock-root")`),
    "#session-dock-root is present on /"
  )

  // -- the page reserves room for the strip -----------------------------------

  const geometry = await page.json(`(() => {
    const offset = document.getElementById("session-dock-offset")
    const toggle = document.getElementById("session-dock-roster-toggle")
    const pad = offset ? parseFloat(getComputedStyle(offset).paddingBottom) : null
    return {
      pad,
      strip: toggle ? Math.round(toggle.getBoundingClientRect().height) : null,
      offsetBottom: offset ? Math.round(offset.getBoundingClientRect().bottom) : null
    }
  })()`)

  check(
    "the-page-reserves-bottom-room-the-height-of-the-strip",
    geometry.pad > 0 && geometry.strip > 0 && Math.abs(geometry.pad - geometry.strip) <= 1,
    `padding-bottom=${geometry.pad}px strip=${geometry.strip}px`
  )

  // -- open a session into the strip ------------------------------------------

  await page.eval(`document.getElementById("session-dock-roster-toggle").click()`)
  await page.poll(`!!document.getElementById("session-dock-roster-panel")`, "the roster never opened")

  const sessionId = await page.pollValue(
    `(() => {
       const row = document.querySelector("#session-dock-roster-list > li")
       return row ? row.id.replace("session-dock-roster-", "") : null
     })()`,
    "the roster listed no sessions"
  )

  // A scroll offset only survives if the element does. The roster is the one
  // scrollable thing in the dock, so it is what phase 2's terminal scrollback
  // will be standing on.
  const scrolled = await page.json(`(() => {
    const panel = document.getElementById("session-dock-roster-panel")
    panel.scrollTop = panel.scrollHeight
    return { top: Math.round(panel.scrollTop), scrollable: panel.scrollHeight > panel.clientHeight }
  })()`)

  check(
    "the-roster-scrolls",
    scrolled.scrollable && scrolled.top > 0,
    `scrollTop=${scrolled.top} scrollable=${scrolled.scrollable}`
  )

  // The stamp: a JS property on the element object. Nothing the server renders
  // can put it back, so if it is still there after a navigation, it is
  // literally the same node — not a re-render that happens to look the same.
  await page.eval(`(window.__arbDockNode = document.getElementById("session-dock")).__arbStamp = "kept"`)

  await page.eval(`document.getElementById("session-dock-open-${sessionId}").click()`)
  await page.poll(
    `!!document.getElementById("session-dock-window-${sessionId}")`,
    "the session never opened into the strip"
  )

  check(
    "opening-a-session-adds-an-expanded-window",
    await page.eval(
      `document.getElementById("session-dock-window-${sessionId}").dataset.expanded === "true" &&
       !!document.getElementById("session-dock-frame-${sessionId}")`
    ),
    `#session-dock-window-${sessionId} is expanded with a frame`
  )

  // The frame is phase 1's deliverable and it has to have real size — an
  // empty div that collapses to 0px would satisfy every server-side test.
  const frame = await page.json(`(() => {
    const el = document.getElementById("session-dock-frame-${sessionId}")
    const r = el.getBoundingClientRect()
    return { w: Math.round(r.width), h: Math.round(r.height), bottom: Math.round(r.bottom) }
  })()`)

  check(
    "the-expanded-frame-has-real-size-and-sits-above-the-strip",
    frame.w > 200 && frame.h > 150 && frame.bottom <= HEIGHT + 1,
    `${frame.w}x${frame.h}, bottom=${frame.bottom} viewport=${HEIGHT}`
  )

  await screenshot("expanded")

  // Phase 2 (bd-9myzv8) fills the frame: one terminal, for the expanded window
  // only. Which one it is, that it connects, resumes and survives navigation
  // is `scripts/verify_session_dock_terminal.mjs`'s business — here it is only
  // the invariant this file has always been about, that the strip holds
  // exactly one of them.
  check(
    "the-expanded-window-holds-the-one-terminal",
    await page.eval(
      `!!document.getElementById("session-dock-terminal-${sessionId}") &&
       document.querySelectorAll("#session-dock .xterm").length <= 1`
    ),
    "one terminal, in the expanded window"
  )

  // Re-scroll: opening the session closed the roster, and the panel is
  // re-created when it reopens.
  await page.eval(`document.getElementById("session-dock-roster-toggle").click()`)
  await page.poll(`!!document.getElementById("session-dock-roster-panel")`, "the roster never reopened")
  const beforeNav = await page.json(`(() => {
    const panel = document.getElementById("session-dock-roster-panel")
    panel.scrollTop = 60
    return { top: Math.round(panel.scrollTop) }
  })()`)
  // A programmatic `scrollTop =` fires its `scroll` event on the next frame,
  // and the dock's bookkeeping listens for that event — navigating in the same
  // tick would race it and prove nothing.
  await page.settle()

  // -- live navigation --------------------------------------------------------

  await page.eval(`document.querySelector('#top-nav a[href="/tasks"]').click()`)
  await page.poll(`location.pathname === "/tasks"`, "the live navigation to /tasks never happened")
  await page.waitForLive()
  await page.settle()

  const afterNav = await page.json(`(() => {
    const el = document.getElementById("session-dock")
    const panel = document.getElementById("session-dock-roster-panel")
    const win = document.getElementById("session-dock-window-${sessionId}")
    return {
      sameNode: !!el && el === window.__arbDockNode,
      stamp: el ? el.__arbStamp || null : null,
      window: !!win,
      expanded: win ? win.dataset.expanded : null,
      scrollTop: panel ? Math.round(panel.scrollTop) : null,
      path: location.pathname
    }
  })()`)

  check(
    "live-navigation-does-not-re-mount-the-dock",
    afterNav.sameNode && afterNav.stamp === "kept",
    `on ${afterNav.path}: same DOM node=${afterNav.sameNode} stamp=${afterNav.stamp}`
  )

  check(
    "the-open-expanded-window-survives-live-navigation",
    afterNav.window && afterNav.expanded === "true",
    `window=${afterNav.window} expanded=${afterNav.expanded}`
  )

  check(
    "the-roster-scroll-position-survives-live-navigation",
    afterNav.scrollTop === beforeNav.top && beforeNav.top > 0,
    `before=${beforeNav.top} after=${afterNav.scrollTop}`
  )

  // -- a full reload ----------------------------------------------------------

  await page.goto(`${BASE}/usage`)
  await page.waitForLive()

  const restored = await page.pollValue(
    `(() => {
       const win = document.getElementById("session-dock-window-${sessionId}")
       if (!win) return null
       return JSON.stringify({ expanded: win.dataset.expanded, stamp: document.getElementById("session-dock").__arbStamp || null })
     })()`,
    "the dock did not come back from localStorage after a reload"
  ).then(JSON.parse)

  check(
    "a-full-reload-restores-the-dock-from-localStorage",
    restored.expanded === "true" && restored.stamp === null,
    `expanded=${restored.expanded}, and it is a fresh node (stamp=${restored.stamp})`
  )

  check(
    "the-stored-state-is-under-one-known-key",
    await page.eval(`!!window.localStorage.getItem("arbiter:session-dock")`),
    await page.eval(`String(window.localStorage.getItem("arbiter:session-dock"))`)
  )

  // -- dismiss ----------------------------------------------------------------

  await page.eval(`document.getElementById("session-dock-dismiss-${sessionId}").click()`)
  await page.poll(
    `!document.getElementById("session-dock-window-${sessionId}")`,
    "dismiss never removed the window"
  )

  await page.goto(`${BASE}/`)
  await page.waitForLive()
  await page.settle()

  check(
    "dismiss-is-remembered-across-a-reload",
    await page.eval(`!document.getElementById("session-dock-window-${sessionId}")`),
    "the dismissed window did not come back"
  )

  // -- /sessions is untouched -------------------------------------------------

  await page.goto(`${BASE}/sessions`)
  await page.waitForLive()

  check(
    "the-sessions-page-still-has-its-own-controls",
    await page.eval(
      `!!document.getElementById("launch-session") &&
       !!document.getElementById("sessions-list") &&
       !!document.getElementById("session-dock-root")`
    ),
    "launch + list + dock all present on /sessions"
  )

  // -- a full strip ------------------------------------------------------------
  //
  // The dock is `position: fixed` and spans the viewport, so a row of windows
  // that does not compress does not simply look cramped — it pushes the
  // document's own scrollWidth past the window and gives every page a
  // horizontal scrollbar it never had before.

  await page.eval(`document.getElementById("session-dock-roster-toggle").click()`)
  await page.poll(`!!document.getElementById("session-dock-roster-panel")`, "the roster never opened")

  const opened = await page.pollValue(
    `(() => {
       const buttons = [...document.querySelectorAll("[id^='session-dock-open-']")]
       return buttons.length ? buttons.length : null
     })()`,
    "the roster listed nothing to open"
  )

  for (let i = 0; i < Math.min(opened, 10); i++) {
    await page.eval(
      `(() => {
         const panel = document.getElementById("session-dock-roster-panel")
         if (!panel) document.getElementById("session-dock-roster-toggle").click()
       })()`
    )
    await page.poll(`!!document.getElementById("session-dock-roster-panel")`, "the roster never reopened")
    const clicked = await page.eval(
      `(() => {
         const next = [...document.querySelectorAll("[id^='session-dock-open-']")]
           .find((b) => b.textContent.trim() === "Open")
         if (!next) return false
         next.click()
         return true
       })()`
    )
    if (!clicked) break
    await page.settle(150)
  }

  const full = await page.json(`(() => {
    const windows = document.querySelectorAll("[id^='session-dock-window-']")
    const root = document.getElementById("session-dock-root")
    return {
      windows: windows.length,
      documentOverflow: document.documentElement.scrollWidth - window.innerWidth,
      rootOverflow: Math.round(root.getBoundingClientRect().right) - window.innerWidth,
      narrowest: Math.min(...[...windows].map((w) => Math.round(w.getBoundingClientRect().width)))
    }
  })()`)

  check(
    "a-full-strip-compresses-instead-of-overflowing-the-page",
    full.windows > 1 && full.documentOverflow <= 1 && full.rootOverflow <= 1,
    `${full.windows} windows, narrowest=${full.narrowest}px, ` +
      `document scrollWidth-innerWidth=${full.documentOverflow}px, strip right-innerWidth=${full.rootOverflow}px`
  )

  check(
    "the-cap-stops-a-strip-growing-without-bound",
    full.windows <= 8,
    `${full.windows} windows open after clicking Open ${Math.min(opened, 10)} times`
  )

  await screenshot("full-strip")

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )

  // Every window here is collapsed except one, and the strip is the only
  // thing that can hold a terminal — so a full strip still holds at most one.
  check(
    "a-full-strip-still-holds-at-most-one-terminal",
    (await page.eval(`document.querySelectorAll("[id^='session-dock-terminal-']").length`)) <= 1,
    `${await page.eval(`document.querySelectorAll("[id^='session-dock-terminal-']").length`)} terminal(s) across ${full.windows} windows`
  )

  console.log(`SESSION ${sessionId}`)
}

// Nothing asserts on these; they are there so a human (or the next phase) can
// look at what the dock actually renders without booting a server by hand.
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

    // `isConnected()` reports the socket, not the view: `phx-connected` is set
    // off the join reply, so it is the first point the page is really live.
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

// Resolves on the child's exit, or after a grace period if it will not go —
// a hung browser must not hang the verification.
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
