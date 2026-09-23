#!/usr/bin/env node
//
// bd-gukyy1 — the quota bars in the status bar, in a real browser.
//
// `ArbiterWeb.QuotaTopbarTest` proves the markup: one `#quota-topbar-<provider>`
// row per provider, two bars each, the chrome still rendered. What it cannot
// prove is that a second provider row actually fits — that the stacked rows sit
// inside the 46px status bar, that the live badge, inbox trigger and theme
// toggle still fit beside them at `lg` (1024px) without overlap or horizontal
// overflow, and that the provider hues resolve to distinct colours that follow
// the dark-mode token redefinitions. `ConnCase` has no layout engine.
//
//   node scripts/verify_quota_topbar.mjs --url http://127.0.0.1:4848 [--shots <dir>]
//
// Needs a Claude and an Antigravity quota row on the default workspace — the
// post-merge check against the running server has both once `agy` is installed.
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a final
// `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser). `--shots <dir>` also
// writes a PNG of the status bar per viewport/theme for a human to look at.
//
// No npm (RFC §6.1): the browser is one already on the machine and the driver
// is the Chrome DevTools Protocol over Node's built-in `WebSocket` and `fetch`.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs"
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
const SHOTS = options.shots || null

// Tailwind's `lg` (64rem) exactly, a roomy desktop, and one below `lg` where
// the bars must be hidden.
const LG = 1024
const WIDE = 1440
const NARROW = 800
const HEIGHT = 900

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-quota-topbar-"))
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

  await run(pageDriver(cdp, sessionId), cdp, sessionId)
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

// Everything a claim below is decided from, read in one evaluate.
function stateScript() {
  return `(() => {
  const rect = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height }
  }
  const shown = (el) => !!el && getComputedStyle(el).display !== "none" && el.getBoundingClientRect().width > 0
  const header = document.getElementById("app-status-bar")
  const topbar = document.getElementById("quota-topbar")
  const rows = [...document.querySelectorAll("#quota-topbar > [id^=quota-topbar-]")]
  const fill = (id) => {
    const el = document.querySelector("#" + id + " [data-quota-fill]")
    return el ? getComputedStyle(el).backgroundColor : null
  }
  return JSON.stringify({
    header: rect(header),
    headerOverflow: header.scrollWidth - header.clientWidth,
    pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    width: window.innerWidth,
    topbarShown: shown(topbar),
    topbar: rect(topbar),
    rows: rows.map((row) => ({
      id: row.id,
      rect: rect(row),
      bars: [...row.querySelectorAll("[data-quota-bar]")].map(rect)
    })),
    chrome: ["appshell-live", "coordinator-inbox-trigger", "theme-toggle"].map((id) => ({
      id,
      shown: shown(document.getElementById(id)),
      rect: rect(document.getElementById(id))
    })),
    claudeFill: fill("quota-topbar-claude-5h"),
    antigravityFill: fill("quota-topbar-antigravity-5h"),
    errored: !!document.querySelector(".phx-error")
  })
})()`
}

async function state(page) {
  return JSON.parse(await page.eval(stateScript()))
}

async function joined(page, what, selector) {
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected") && !!document.querySelector(${JSON.stringify(selector)})
     })()`,
    `${what} never joined`
  )
}

function overlaps(a, b) {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
}

function px(n) {
  return `${Math.round(n * 10) / 10}px`
}

async function screenshot(cdp, sessionId, name, clip) {
  if (!SHOTS || !clip) return
  const { data } = await cdp.send(
    "Page.captureScreenshot",
    { format: "png", clip: { x: 0, y: 0, width: clip.width, height: clip.height, scale: 1 } },
    sessionId
  )
  writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"))
}

async function run(page, cdp, sessionId) {
  const fills = {}

  for (const width of [LG, WIDE]) {
    for (const theme of ["light", "dark"]) {
      const tag = `${width}px/${theme}`
      await page.resizeViewport(width, HEIGHT)
      await page.goto(`${BASE}/`)
      await joined(page, `/ at ${tag}`, "#app-status-bar")
      await page.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
      await page.settle()
      const s = await state(page)

      check(`${tag} bars shown`, s.topbarShown, `#quota-topbar displayed: ${s.topbarShown}`)

      const ids = s.rows.map((r) => r.id)
      check(
        `${tag} one row per provider`,
        ids.includes("quota-topbar-claude") && ids.includes("quota-topbar-antigravity"),
        `rows: ${ids.join(", ")}`
      )

      const stacked = s.rows.every((r, i) => i === 0 || r.rect.top >= s.rows[i - 1].rect.bottom - 0.5)
      check(`${tag} rows stack vertically`, stacked, s.rows.map((r) => `${r.id} ${px(r.rect.top)}–${px(r.rect.bottom)}`).join("; "))

      const sideBySide = s.rows.every(
        (r) => r.bars.length === 2 && r.bars[1].left >= r.bars[0].right - 0.5 && Math.abs(r.bars[1].top - r.bars[0].top) < 1
      )
      check(`${tag} windows side by side`, sideBySide, s.rows.map((r) => `${r.id}: ${r.bars.length} bars`).join("; "))

      const inside = s.topbar && s.topbar.top >= s.header.top - 0.5 && s.topbar.bottom <= s.header.bottom + 0.5
      check(
        `${tag} rows fit the status bar`,
        inside,
        `quota ${px(s.topbar.top)}–${px(s.topbar.bottom)} within header ${px(s.header.top)}–${px(s.header.bottom)}`
      )

      const chromeOk = s.chrome.every(
        (c) => c.shown && c.rect.right <= s.width + 0.5 && !overlaps(c.rect, s.topbar)
      )
      check(
        `${tag} chrome still fits beside the bars`,
        chromeOk,
        s.chrome.map((c) => `${c.id} shown=${c.shown} ${px(c.rect.left)}–${px(c.rect.right)}`).join("; ") +
          `; quota ${px(s.topbar.left)}–${px(s.topbar.right)}; viewport ${s.width}`
      )

      check(
        `${tag} no horizontal overflow`,
        s.pageOverflow <= 0 && s.headerOverflow <= 0,
        `page ${s.pageOverflow}px, status bar ${s.headerOverflow}px`
      )

      check(
        `${tag} provider hues are distinct`,
        s.claudeFill && s.antigravityFill && s.claudeFill !== s.antigravityFill,
        `claude ${s.claudeFill}, antigravity ${s.antigravityFill}`
      )

      check(`${tag} page healthy`, !s.errored, `phx-error present: ${s.errored}`)
      fills[`${width}/${theme}`] = s.claudeFill
      await screenshot(cdp, sessionId, `topbar-${width}-${theme}`, { width, height: Math.ceil(s.header.bottom) })
    }
  }

  check(
    "hues follow the dark-mode tokens",
    fills[`${LG}/light`] !== fills[`${LG}/dark`],
    `claude light ${fills[`${LG}/light`]}, dark ${fills[`${LG}/dark`]}`
  )

  await page.resizeViewport(NARROW, HEIGHT)
  await page.goto(`${BASE}/`)
  await joined(page, `/ at ${NARROW}px`, "#app-status-bar")
  const narrow = await state(page)
  check(`${NARROW}px bars hidden below lg`, !narrow.topbarShown, `#quota-topbar displayed: ${narrow.topbarShown}`)

  await page.resizeViewport(WIDE, HEIGHT)
  await page.goto(`${BASE}/usage`)
  await joined(page, "/usage", "#usage-quota-antigravity")
  const usage = JSON.parse(
    await page.eval(`JSON.stringify({
      bars: document.querySelectorAll("#usage-quota-antigravity [data-quota-bar]").length,
      claude: document.querySelectorAll("#usage-quota-claude [data-quota-bar]").length,
      overflow: document.documentElement.scrollWidth - window.innerWidth
    })`)
  )
  check("/usage antigravity four bars, claude two", usage.bars === 4 && usage.claude === 2, `antigravity ${usage.bars}, claude ${usage.claude}`)
  check("/usage no horizontal overflow", usage.overflow <= 0, `${usage.overflow}px`)
  if (SHOTS) {
    const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId)
    writeFileSync(path.join(SHOTS, "usage-1440.png"), Buffer.from(data, "base64"))
  }

  check("no console errors", consoleErrors.length === 0, consoleErrors.slice(0, 3).join(" | ") || "none")
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
