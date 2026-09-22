#!/usr/bin/env node
//
// bd-d63b1c — the nav rail in a real browser, at real viewports.
//
// `ArbiterWeb.LayoutsTest` proves the markup: the rail is `position: fixed`,
// out of `<main>`, and `app.css` never mentions `:hover` in an inset rule.
// What it cannot prove is where the browser actually puts things — that the
// hover float really does not reflow the page, that pinning really does, that
// a pin set in localStorage is applied before first paint, and that the
// below-`lg` overlay opens and closes. `ConnCase` has no layout engine.
//
//   node scripts/verify_nav_rail.mjs --url http://127.0.0.1:4848 [--run <run id>]
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a final
// `RESULT: PASS|FAIL`. `ArbiterWeb.NavRailBrowserTest` runs it against a
// Bandit listener as part of `mix test`; exit 3 means SKIP (no browser). The
// same script serves the post-merge check against the running server — it
// clears only its own `arbiter:nav-rail` key, in its own throwaway profile.
//
// No npm (RFC §6.1): the browser is one already on the machine and the driver
// is the Chrome DevTools Protocol over Node's built-in `WebSocket` and `fetch`.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs"
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
const BASE = (options.url || "http://127.0.0.1:4848").replace(/\/$/, "")
const DEADLINE_MS = Number(options.seconds || 30) * 1000
const RUN = options.run || null

// The width the ticket names, and one below Tailwind's `lg` (64rem).
const WIDE = 1280
const NARROW = 800
const HEIGHT = 900

// `--nav-rail-width`, `--nav-rail-width-expanded`, `--nav-height`,
// `--session-dock-strip-height` from app.css.
const RAIL = 56
const RAIL_EXPANDED = 200
const NAV_HEIGHT = 46
const STRIP = 34

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-nav-rail-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${WIDE},${HEIGHT}`,
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank"
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
)

let cdp = null

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

  await run(pageDriver(cdp, sessionId))
} catch (error) {
  check("harness", false, (error && error.stack) || String(error))
} finally {
  if (cdp) cdp.close()
  // Exact-PID teardown only. This repo has an incident class around
  // pattern-matching kills reaching the live coordinator.
  browser.kill("SIGTERM")
  await exited(browser)
  // Chromium keeps writing into its profile until it is actually gone, so a
  // removal issued alongside the signal loses the race under load
  // (`ENOTEMPTY`). Wait for the exit, retry, and never let cleanup decide the
  // verdict — every CHECK has already been printed by this point.
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

// Everything a claim below is decided from, read in one evaluate.
function stateScript() {
  return `(() => {
  const html = document.documentElement
  const rail = document.getElementById("nav-rail")
  const main = document.querySelector("main")
  const first = main && main.firstElementChild
  const pin = document.querySelector('#nav-rail [phx-click="toggle-nav-pin"]')
  const label = document.querySelector("#nav-rail a > .truncate")
  const backdrop = document.getElementById("nav-rail-backdrop")
  const toggle = document.getElementById("nav-rail-toggle")
  const r = rail.getBoundingClientRect()
  let stored = null
  try { stored = localStorage.getItem("arbiter:nav-rail") } catch (_e) {}
  return JSON.stringify({
    path: location.pathname,
    attr: html.getAttribute("data-nav-rail"),
    open: html.hasAttribute("data-nav-rail-open"),
    inset: parseFloat(getComputedStyle(html).getPropertyValue("--nav-rail-page-inset")) || 0,
    mainPad: parseFloat(getComputedStyle(main).paddingLeft),
    firstLeft: first ? first.getBoundingClientRect().left : null,
    railDisplay: getComputedStyle(rail).display,
    railPosition: getComputedStyle(rail).position,
    railWidth: r.width,
    railTop: r.top,
    railBottom: window.innerHeight - r.bottom,
    railInMain: !!(main && main.contains(rail)),
    labelOpacity: label ? getComputedStyle(label).opacity : null,
    pressed: pin ? pin.getAttribute("aria-pressed") : null,
    backdrop: getComputedStyle(backdrop).display,
    toggleShown: getComputedStyle(toggle).display !== "none",
    expanded: toggle.getAttribute("aria-expanded"),
    stored,
    // Page-wide, as acceptance criterion 10 counts it; and the rail's own,
    // for pages whose content has a current item of its own (a filter tab).
    current: [...document.querySelectorAll('[aria-current="page"]')].map((e) => e.textContent.trim()),
    railCurrent: [...document.querySelectorAll('#nav-rail [aria-current="page"]')].map((e) => e.textContent.trim()),
    barLinks: document.querySelectorAll("#app-status-bar a[href], #app-status-bar nav").length,
    overflow: document.documentElement.scrollWidth - window.innerWidth,
    marker: window.__navRailMarker || null,
    firstPaintPad: window.__navRailFirstPaintPad || null,
    errored: !!document.querySelector(".phx-error")
  })
})()`
}

async function state(page) {
  return JSON.parse(await page.eval(stateScript()))
}

function center(page, selector) {
  return page
    .eval(
      `(() => {
         const el = document.querySelector(${JSON.stringify(selector)})
         if (!el) return null
         const r = el.getBoundingClientRect()
         return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2 })
       })()`
    )
    .then((v) => (v ? JSON.parse(v) : null))
}

async function joined(page, what) {
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected") && !!document.getElementById("nav-rail")
     })()`,
    `${what} never joined`
  )
}

async function clickOn(page, selector) {
  const at = await center(page, selector)
  if (!at) throw new Error(`nothing to click at ${selector}`)
  await page.click(at.x, at.y)
}

// Parks the pointer on the page body, well clear of the rail and the dock.
function away(page, width) {
  return page.mouseMove(width / 2, HEIGHT / 2)
}

function same(a, b) {
  return Math.abs(a - b) < 0.5
}

async function run(page) {
  // What the page looked like before any hook ran: `theme.js` is the only
  // script ahead of first paint, so this reads what it set up.
  await page.onNewDocument(`
    document.addEventListener("DOMContentLoaded", () => {
      const main = document.querySelector("main")
      if (main) window.__navRailFirstPaintPad = getComputedStyle(main).paddingLeft
    })
  `)

  await page.resizeViewport(WIDE, HEIGHT)
  await page.goto(`${BASE}/`)
  await page.eval(`localStorage.removeItem("arbiter:nav-rail")`)
  await page.goto(`${BASE}/`)
  await joined(page, "the board")
  await away(page, WIDE)
  await page.settle()

  // -- collapsed, at 1280 ------------------------------------------------------

  const s0 = await state(page)
  check(
    "collapsed-rail-is-a-fixed-icon-column-between-bar-and-strip",
    s0.railPosition === "fixed" && same(s0.railWidth, RAIL) && same(s0.railTop, NAV_HEIGHT) &&
      same(s0.railBottom, STRIP) && !s0.railInMain,
    `position=${s0.railPosition} width=${s0.railWidth} top=${s0.railTop} bottom-gap=${s0.railBottom} inMain=${s0.railInMain}`
  )
  check(
    "unpinned-inset-is-the-collapsed-rail-width",
    s0.attr === "collapsed" && same(s0.inset, RAIL) && same(s0.mainPad, RAIL),
    `data-nav-rail=${s0.attr} inset=${s0.inset} main padding-left=${s0.mainPad}`
  )
  check("collapsed-labels-are-hidden", s0.labelOpacity === "0", `label opacity=${s0.labelOpacity}`)
  check("board-has-no-horizontal-page-scroll-at-1280", s0.overflow <= 0, `overflow=${s0.overflow}px`)
  check(
    "board-has-exactly-one-current-item",
    s0.current.length === 1 && s0.current[0] === "Board",
    `aria-current=${JSON.stringify(s0.current)}`
  )
  check("status-bar-holds-no-links", s0.barLinks === 0, `links/navs in the bar=${s0.barLinks}`)

  // -- hover float -------------------------------------------------------------

  await page.mouseMove(RAIL / 2, NAV_HEIGHT + 200)
  await page.settle(700)
  const s1 = await state(page)
  check(
    "hover-floats-the-rail-open",
    same(s1.railWidth, RAIL_EXPANDED) && s1.labelOpacity === "1",
    `width=${s1.railWidth} label opacity=${s1.labelOpacity}`
  )
  check(
    "hover-leaves-the-inset-and-the-page-where-they-were",
    same(s1.inset, RAIL) && same(s1.mainPad, RAIL) && same(s1.firstLeft, s0.firstLeft),
    `inset=${s1.inset} main padding-left=${s1.mainPad} content left ${s0.firstLeft} -> ${s1.firstLeft}`
  )

  // -- pin ---------------------------------------------------------------------

  const pinBefore = await center(page, '#nav-rail [phx-click="toggle-nav-pin"]')
  await clickOn(page, '#nav-rail [phx-click="toggle-nav-pin"]')
  await page.settle(500)
  const s2 = await state(page)
  check(
    "the-pin-does-not-move-when-the-rail-floats-open",
    pinBefore && same(pinBefore.x, 26),
    `pin centre x=${pinBefore && pinBefore.x} (icon column centre 26)`
  )
  check(
    "pinning-insets-the-page-by-the-expanded-width",
    s2.attr === "pinned" && same(s2.inset, RAIL_EXPANDED) && same(s2.mainPad, RAIL_EXPANDED) &&
      same(s2.firstLeft, s0.firstLeft + (RAIL_EXPANDED - RAIL)),
    `data-nav-rail=${s2.attr} inset=${s2.inset} main padding-left=${s2.mainPad} content left ${s0.firstLeft} -> ${s2.firstLeft}`
  )
  check(
    "the-pin-is-stored-and-pressed",
    s2.stored === "pinned" && s2.pressed === "true",
    `localStorage=${s2.stored} aria-pressed=${s2.pressed}`
  )
  check(
    "the-pin-never-reached-the-server",
    !s2.errored && s2.path === "/",
    `phx-error=${s2.errored} path=${s2.path}`
  )

  await away(page, WIDE)
  await page.settle(500)
  const s3 = await state(page)
  check(
    "a-pinned-rail-stays-open-without-hover",
    same(s3.railWidth, RAIL_EXPANDED) && s3.overflow <= 0,
    `width=${s3.railWidth} overflow=${s3.overflow}px`
  )

  // -- live navigation ---------------------------------------------------------

  await page.eval(`window.__navRailMarker = "same-document"`)
  await clickOn(page, '#nav-rail a[href="/workers/history"]')
  await page.poll(`location.pathname === "/workers/history"`, "never navigated to /workers/history")
  await joined(page, "run history")
  await page.settle()
  const s4 = await state(page)
  check(
    "the-pin-survives-a-live-navigation",
    s4.marker === "same-document" && s4.attr === "pinned" && same(s4.mainPad, RAIL_EXPANDED) &&
      s4.pressed === "true",
    `live=${s4.marker === "same-document"} data-nav-rail=${s4.attr} main padding-left=${s4.mainPad} aria-pressed=${s4.pressed}`
  )
  check(
    "run-history-lights-up-one-rail-item",
    s4.railCurrent.length === 1 && s4.railCurrent[0] === "Run history",
    `rail aria-current=${JSON.stringify(s4.railCurrent)}`
  )

  if (RUN) {
    await page.goto(`${BASE}/workers/history/${RUN}`)
    await joined(page, "the run detail page")
    const s5 = await state(page)
    check(
      "a-run-detail-page-lights-up-run-history-only",
      s5.current.length === 1 && s5.current[0] === "Run history",
      `aria-current=${JSON.stringify(s5.current)}`
    )
  }

  // -- full reload -------------------------------------------------------------

  await page.goto(`${BASE}/workers/history`)
  await joined(page, "run history after a reload")
  const s6 = await state(page)
  check(
    "the-pin-survives-a-full-reload-before-first-paint",
    s6.attr === "pinned" && s6.firstPaintPad === `${RAIL_EXPANDED}px` && same(s6.mainPad, RAIL_EXPANDED),
    `data-nav-rail=${s6.attr} padding-left at DOMContentLoaded=${s6.firstPaintPad} after join=${s6.mainPad}`
  )

  await page.mouseMove(RAIL / 2, NAV_HEIGHT + 200)
  await page.settle(500)
  await clickOn(page, '#nav-rail [phx-click="toggle-nav-pin"]')
  await away(page, WIDE)
  await page.settle(500)
  const s7 = await state(page)
  check(
    "unpinning-gives-the-width-back",
    s7.attr === "collapsed" && same(s7.mainPad, RAIL) && same(s7.railWidth, RAIL) && s7.stored === null,
    `data-nav-rail=${s7.attr} main padding-left=${s7.mainPad} width=${s7.railWidth} localStorage=${s7.stored}`
  )

  // -- below lg ----------------------------------------------------------------

  await page.resizeViewport(NARROW, HEIGHT)
  await page.settle(500)
  const n0 = await state(page)
  check(
    "below-lg-the-rail-is-hidden-and-the-page-takes-the-full-width",
    n0.railDisplay === "none" && same(n0.inset, 0) && same(n0.mainPad, 0) && n0.toggleShown,
    `rail display=${n0.railDisplay} inset=${n0.inset} main padding-left=${n0.mainPad} hamburger shown=${n0.toggleShown}`
  )

  await clickOn(page, "#nav-rail-toggle")
  await page.settle(400)
  const n1 = await state(page)
  check(
    "the-hamburger-opens-the-rail-as-an-overlay",
    n1.open && n1.railDisplay !== "none" && n1.railPosition === "fixed" &&
      same(n1.railWidth, RAIL_EXPANDED) && n1.backdrop !== "none" && same(n1.mainPad, 0) &&
      n1.expanded === "true",
    `open=${n1.open} display=${n1.railDisplay} width=${n1.railWidth} backdrop=${n1.backdrop} main padding-left=${n1.mainPad} aria-expanded=${n1.expanded}`
  )

  await page.click(NARROW - 40, HEIGHT / 2)
  await page.settle(400)
  const n2 = await state(page)
  check(
    "a-backdrop-click-dismisses-the-overlay",
    !n2.open && n2.railDisplay === "none" && n2.backdrop === "none" && n2.expanded === "false",
    `open=${n2.open} display=${n2.railDisplay} backdrop=${n2.backdrop} aria-expanded=${n2.expanded}`
  )

  await clickOn(page, "#nav-rail-toggle")
  await page.settle(400)
  await clickOn(page, '#nav-rail a[href="/tasks"]')
  await page.poll(`location.pathname === "/tasks"`, "never navigated to /tasks")
  await joined(page, "the issues page")
  await page.settle()
  const n3 = await state(page)
  check(
    "navigating-to-an-item-closes-the-overlay",
    !n3.open && n3.railDisplay === "none" && n3.backdrop === "none",
    `path=${n3.path} open=${n3.open} display=${n3.railDisplay} backdrop=${n3.backdrop}`
  )

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length === 0 ? "none" : consoleErrors.slice(0, 5).join(" | ")
  )
}

// -- the page driver ----------------------------------------------------------

function pageDriver(cdp, sessionId) {
  const driver = {
    async goto(url) {
      await cdp.send("Page.navigate", { url }, sessionId)
      await driver.poll(`document.readyState === "complete"`, `${url} never finished loading`)
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

    async onNewDocument(source) {
      await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source }, sessionId)
    },

    async mouseMove(x, y) {
      await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y }, sessionId)
    },

    // A trusted click: pointer there first, so `:hover` is what a real
    // operator would have had at the moment of the press.
    async click(x, y) {
      await driver.mouseMove(x, y)
      for (const type of ["mousePressed", "mouseReleased"]) {
        await cdp.send(
          "Input.dispatchMouseEvent",
          { type, x, y, button: "left", clickCount: 1 },
          sessionId
        )
      }
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
