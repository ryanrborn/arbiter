#!/usr/bin/env node
//
// bd-2wmxt5 — the `/epics` page in a real browser, at a real narrow width.
//
// `ArbiterWeb.EpicIndexLiveTest` proves the page's data: the right epics, the
// right buckets, the right chips, live on PubSub. What it cannot prove is
// acceptance criterion 6 — "usable at ~400px width, with rows stacked" —
// because `ConnCase` has no layout engine. Asserting that a row carries
// `flex-col sm:flex-row` is a claim about a class attribute, not about where
// the browser actually puts the two halves of the row, and a stray
// `min-w-[...]` or a non-truncating title would blow the row past the viewport
// with those exact classes still in place.
//
// So this loads the page in headless Chromium and measures it:
//
//   node scripts/verify_epics_page.mjs --url http://127.0.0.1:4848 --epic bd-xxxx
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a final
// `RESULT: PASS|FAIL`. `ArbiterWeb.EpicPageBrowserTest` runs it against a
// Bandit listener as part of `mix test`; exit 3 means SKIP (no browser).
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
const EPIC = options.epic || null
const EXPECTED_BADGE = options.badge ? Number(options.badge) : null

// The breakpoint the row stacks below, and the width the ticket names.
const NARROW = 400
const WIDE = 1280

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-epics-page-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${WIDE},900`,
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

async function run(page) {
  await page.resizeViewport(WIDE, 900)
  await page.goto(`${BASE}/epics`)

  // `isConnected()` reports the socket, not the view: `phx-connected` is set
  // off the join reply, so it is the first point the page is really live.
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected")
     })()`,
    "the /epics LiveView never joined"
  )

  const row = EPIC ? `#epic-${cssEscape(EPIC)}` : "#epics > li"

  const present = await page.eval(
    `(() => {
       const list = document.getElementById("epics")
       const row = document.querySelector(${JSON.stringify(row)})
       return JSON.stringify({ list: !!list, row: !!row, rows: list ? list.children.length : 0 })
     })()`
  )
  const seen = JSON.parse(present)
  check("page-renders-epic-rows", seen.list && seen.row, `list=${seen.list} rows=${seen.rows}`)
  if (!seen.row) return

  // -- the nav badge ----------------------------------------------------------

  const badge = await page.eval(
    `(() => {
       const el = document.querySelector('#nav-rail a[href="/epics"] [data-role="nav-badge"]')
       return el ? el.textContent.trim() : null
     })()`
  )
  check(
    "nav-badge-shows-the-open-epic-count",
    EXPECTED_BADGE === null ? badge !== null : Number(badge) === EXPECTED_BADGE,
    `badge=${badge} expected=${EXPECTED_BADGE === null ? "(any)" : EXPECTED_BADGE}`
  )

  // -- the row's two halves, wide then narrow ---------------------------------

  await page.settle()
  const wide = await measureRow(page, row)
  check(
    "row-is-side-by-side-above-the-breakpoint",
    wide.layout === "side-by-side",
    `at ${WIDE}px the row is ${wide.layout} (${describe(wide)})`
  )

  await page.resizeViewport(NARROW, 900)
  await page.settle(500)
  const narrow = await measureRow(page, row)

  check(
    "row-stacks-at-400px",
    narrow.layout === "stacked",
    `at ${NARROW}px the row is ${narrow.layout} (${describe(narrow)})`
  )

  // Naming the offender is the whole value of this check: "the page is 33px
  // too wide" sends you reading the entire template, "#epics-filter-sort
  // reaches 433px" sends you to one line.
  const offenders = await page.eval(
    `(() => {
       const limit = window.innerWidth + 1
       const out = []
       for (const el of document.querySelectorAll("body *")) {
         const r = el.getBoundingClientRect()
         if (r.width === 0 || r.right <= limit) continue
         // Only the innermost offender of a chain is interesting; a parent is
         // wide because its child is.
         if ([...el.children].some((c) => c.getBoundingClientRect().right > limit)) continue
         out.push(
           (el.id ? "#" + el.id : el.tagName.toLowerCase()) +
             (el.className && typeof el.className === "string"
               ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".")
               : "") +
             " right=" + Math.round(r.right)
         )
       }
       return JSON.stringify(out.slice(0, 5))
     })()`
  )

  check(
    "nothing-overflows-the-viewport-at-400px",
    narrow.documentOverflow <= 1 && narrow.rowOverflow <= 1,
    `document scrollWidth-innerWidth=${round(narrow.documentOverflow)}px, ` +
      `row scrollWidth-clientWidth=${round(narrow.rowOverflow)}px` +
      (narrow.documentOverflow > 1 ? `, widest: ${offenders}` : "")
  )

  // Every part of a row has to survive the squeeze, not just its box: a chip
  // or the progress bar collapsing to zero is the usual way "it fits" and "it
  // is usable" come apart.
  const parts = await page.eval(
    `(() => {
       const row = document.querySelector(${JSON.stringify(row)})
       const measure = (sel) => {
         const el = row.querySelector(sel)
         if (!el) return null
         const r = el.getBoundingClientRect()
         return { w: r.width, h: r.height }
       }
       return JSON.stringify({
         title: measure("a[href^='/tasks/']"),
         progress: measure("[id$='-progress']"),
         breakdown: measure("[id$='-breakdown']"),
         bar: measure("[role='img']"),
         chip: measure("[data-role='stuck-chips'] .badge")
       })
     })()`
  )
  const p = JSON.parse(parts)
  const visible = (part) => part && part.w > 0 && part.h > 0

  check(
    "every-part-of-the-row-is-still-drawn-at-400px",
    ["title", "progress", "breakdown", "bar"].every((k) => visible(p[k])),
    Object.entries(p)
      .map(([k, v]) => `${k}=${v ? `${round(v.w)}x${round(v.h)}` : "absent"}`)
      .join(" ")
  )

  check(
    "the-stuck-chip-is-still-drawn-at-400px",
    visible(p.chip),
    p.chip ? `${round(p.chip.w)}x${round(p.chip.h)}` : "no stuck chip on this row"
  )

  // -- the filter bar has to survive the squeeze too --------------------------

  const filters = await page.eval(
    `(() => {
       const form = document.getElementById("epics-filter-form")
       if (!form) return JSON.stringify({ error: "no filter form" })
       const r = form.getBoundingClientRect()
       const tops = [...form.children].map((c) => Math.round(c.getBoundingClientRect().top))
       return JSON.stringify({
         overflow: form.scrollWidth - form.clientWidth,
         height: r.height,
         lines: new Set(tops).size
       })
     })()`
  )
  const f = JSON.parse(filters)
  check(
    "the-filter-bar-wraps-instead-of-overflowing-at-400px",
    !f.error && f.overflow <= 1 && f.lines > 1,
    f.error || `overflow=${round(f.overflow)}px height=${round(f.height)}px rows=${f.lines}`
  )

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )
}

// The row is a flex container with exactly two children — identity on the
// left, progress on the right. "Stacked" means the second starts below the
// first; "side-by-side" means it starts to the right of it.
async function measureRow(page, selector) {
  const raw = await page.eval(
    `(() => {
       const row = document.querySelector(${JSON.stringify(selector)})
       if (!row) return JSON.stringify({ error: "the row is gone" })
       const [a, b] = [...row.children].map((c) => c.getBoundingClientRect())
       if (!a || !b) return JSON.stringify({ error: "the row does not have two halves" })
       return JSON.stringify({
         a: { top: a.top, bottom: a.bottom, left: a.left, right: a.right, width: a.width },
         b: { top: b.top, bottom: b.bottom, left: b.left, right: b.right, width: b.width },
         rowOverflow: row.scrollWidth - row.clientWidth,
         documentOverflow: document.documentElement.scrollWidth - window.innerWidth
       })
     })()`
  )

  const m = JSON.parse(raw)
  if (m.error) return { layout: m.error, rowOverflow: 0, documentOverflow: 0 }

  m.layout =
    m.b.top >= m.a.bottom - 0.5
      ? "stacked"
      : m.b.left >= m.a.right - 0.5
        ? "side-by-side"
        : "overlapping"

  return m
}

function describe(m) {
  if (!m.a) return "unmeasurable"
  return (
    `left ${round(m.a.left)}..${round(m.a.right)} x ${round(m.a.top)}..${round(m.a.bottom)}; ` +
    `right ${round(m.b.left)}..${round(m.b.right)} x ${round(m.b.top)}..${round(m.b.bottom)}`
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

// Issue ids are `prefix-suffix`, so they are CSS-safe already, but an id that
// starts with a digit is not a valid bare selector — escape defensively.
function cssEscape(id) {
  return id.replace(/[^a-zA-Z0-9_-]/g, "\\$&").replace(/^(\d)/, "\\3$1 ")
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

function round(n) {
  return Math.round(n * 10) / 10
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
