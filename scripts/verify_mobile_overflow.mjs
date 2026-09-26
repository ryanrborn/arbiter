#!/usr/bin/env node
//
// bd-39kw9e — Usage, Issue detail and Audit pages at phone width.
//
// Three LiveViews overflow/squish at 375-414px: the Usage page's time-range
// toggles bleed off the right edge, the Issue detail action-button row
// doesn't wrap, and the Audit table's Detail column collapses toward zero
// width (rendering as a vertical stack of single characters). None of that
// is visible to ConnCase — it has no layout engine — so this drives real
// headless Chromium against a real Bandit listener and measures the boxes.
//
//   node scripts/verify_mobile_overflow.mjs --url http://127.0.0.1:4848 \
//     --task bd-xxxx --seconds 30 [--screenshots /tmp/out]
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`. Exit 3 means SKIP (no browser on this host).

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs"
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
const TASK = options.task || null
const SCREENSHOT_DIR = options.screenshots || null

if (SCREENSHOT_DIR) mkdirSync(SCREENSHOT_DIR, { recursive: true })

const WIDTHS = [375, 414, 1280]
const THEMES = ["light", "dark"]

// The app-shell header (Layouts.app/1) used to overflow the viewport by ~4px
// at 375px on every page in the app, from its fixed gap/padding leaving no
// room for the live badge + inbox trigger + theme toggle cluster. Trimmed the
// header's gap/padding below `sm` (layouts.ex) so the shell itself fits; this
// residual is just measurement slack (subpixel rounding, scrollbar-gutter),
// not real page content overflow.
const KNOWN_SHELL_OVERFLOW_PX = 1

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-mobile-overflow-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    "--window-size=1280,900",
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

  const page = pageDriver(cdp, sessionId)

  await run(page)

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )
} catch (error) {
  check("harness", false, (error && error.stack) || String(error))
} finally {
  if (cdp) cdp.close()
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
  await checkUsagePage(page)
  await checkTaskDetailPage(page)
  await checkAuditPage(page)
}

async function forEachWidthAndTheme(page, path, fn) {
  for (const width of WIDTHS) {
    await page.resizeViewport(width, 900)
    await page.goto(`${BASE}${path}`)
    await page.pollMain()

    for (const theme of THEMES) {
      await page.setTheme(theme)
      await page.settle(150)
      await fn(width, theme)
      await screenshot(page, path, width, theme)
    }
  }
}

async function screenshot(page, urlPath, width, theme) {
  if (!SCREENSHOT_DIR) return
  const data = await page.screenshot()
  const name = `${urlPath.replace(/\W+/g, "-").replace(/^-|-$/g, "")}_${width}px_${theme}.png`
  writeFileSync(path.join(SCREENSHOT_DIR, name), Buffer.from(data, "base64"))
}

// -- Usage: the time-range toggles must wrap/stay inside their container ------

async function checkUsagePage(page) {
  await forEachWidthAndTheme(page, "/usage", async (width, theme) => {
    const m = await page.eval(
      `(() => {
         const seg = document.querySelector("[phx-click='range']")?.closest("div")
         return JSON.stringify({
           documentOverflow: document.documentElement.scrollWidth - window.innerWidth,
           segRight: seg ? seg.getBoundingClientRect().right : null
         })
       })()`
    )
    const d = JSON.parse(m)

    const offenders = d.documentOverflow > 1 ? await page.offenders() : []
    check(
      `usage-no-page-overflow-${width}px-${theme}`,
      d.documentOverflow <= KNOWN_SHELL_OVERFLOW_PX,
      `document scrollWidth-innerWidth=${round(d.documentOverflow)}px` +
        (offenders.length ? `, widest: ${offenders}` : "")
    )

    check(
      `usage-range-toggle-stays-inside-viewport-${width}px-${theme}`,
      d.segRight !== null && d.segRight <= width + 1,
      `segmented-control right=${d.segRight === null ? "absent" : round(d.segRight)} viewport=${width}`
    )
  })
}

// -- Issue detail: the action-button row must wrap, not overflow -------------

async function checkTaskDetailPage(page) {
  if (!TASK) {
    check("task-detail-skipped", true, "no --task id given")
    return
  }

  await forEachWidthAndTheme(page, `/tasks/${TASK}`, async (width, theme) => {
    const m = await page.eval(
      `(() => {
         const buttons = [...document.querySelectorAll("button, a")]
           .filter(el => ["Edit", "Dispatch", "Close", "Move to Ready"].some(l => el.textContent.trim().startsWith(l)))
         const tops = new Set(buttons.map(b => Math.round(b.getBoundingClientRect().top)))
         return JSON.stringify({
           documentOverflow: document.documentElement.scrollWidth - window.innerWidth,
           buttonCount: buttons.length,
           lines: tops.size,
           maxRight: Math.max(0, ...buttons.map(b => b.getBoundingClientRect().right))
         })
       })()`
    )
    const d = JSON.parse(m)

    const offenders = d.documentOverflow > 1 ? await page.offenders() : []
    check(
      `task-detail-no-page-overflow-${width}px-${theme}`,
      d.documentOverflow <= KNOWN_SHELL_OVERFLOW_PX,
      `document scrollWidth-innerWidth=${round(d.documentOverflow)}px, buttons=${d.buttonCount}` +
        (offenders.length ? `, widest: ${offenders}` : "")
    )

    check(
      `task-detail-action-buttons-fit-viewport-${width}px-${theme}`,
      d.buttonCount === 0 || d.maxRight <= width + 1,
      `maxRight=${round(d.maxRight)} viewport=${width} lines=${d.lines}`
    )
  })
}

// -- Audit: the table must scroll inside its own container, detail readable --

async function checkAuditPage(page) {
  await forEachWidthAndTheme(page, "/audit", async (width, theme) => {
    const m = await page.eval(
      `(() => {
         const container = document.getElementById("audit-table")
         const detailCell = container ? container.querySelector("[role='row']:nth-of-type(2) [role='cell']:last-child") : null
         return JSON.stringify({
           documentOverflow: document.documentElement.scrollWidth - window.innerWidth,
           containerPresent: !!container,
           detailWidth: detailCell ? detailCell.getBoundingClientRect().width : null,
           detailText: detailCell ? detailCell.textContent.trim() : null
         })
       })()`
    )
    const d = JSON.parse(m)

    const offenders = d.documentOverflow > 1 ? await page.offenders() : []
    check(
      `audit-no-page-overflow-${width}px-${theme}`,
      d.documentOverflow <= KNOWN_SHELL_OVERFLOW_PX,
      `document scrollWidth-innerWidth=${round(d.documentOverflow)}px` +
        (offenders.length ? `, widest: ${offenders}` : "")
    )

    // A squished Detail column renders one character per line; a readable one
    // is comfortably wider than a handful of pixels. 100px is well below the
    // 220px minimum the fix gives it, so this only fails on a real regression.
    check(
      `audit-detail-column-is-readable-${width}px-${theme}`,
      !d.containerPresent || d.detailWidth === null || d.detailWidth > 100,
      `detailWidth=${d.detailWidth === null ? "no rows" : round(d.detailWidth)} text=${JSON.stringify(d.detailText)}`
    )
  })
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

    async pollMain() {
      await driver.poll(
        `(() => {
           if (!window.liveSocket || !window.liveSocket.isConnected()) return false
           const main = document.querySelector("[data-phx-main]")
           return !!main && main.classList.contains("phx-connected")
         })()`,
        "the LiveView never joined"
      )
    },

    async setTheme(theme) {
      await driver.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
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
    },

    async screenshot() {
      const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId)
      return data
    },

    async offenders() {
      const raw = await driver.eval(
        `(() => {
           const limit = window.innerWidth + 1
           const out = []
           for (const el of document.querySelectorAll("body *")) {
             const r = el.getBoundingClientRect()
             if (r.width === 0 || r.right <= limit) continue
             if ([...el.children].some((c) => c.getBoundingClientRect().right > limit)) continue
             out.push(
               (el.id ? "#" + el.id : el.tagName.toLowerCase()) +
                 (el.className && typeof el.className === "string"
                   ? "." + el.className.trim().split(/\\s+/).slice(0, 3).join(".")
                   : "") +
                 " right=" + Math.round(r.right)
             )
           }
           return JSON.stringify(out.slice(0, 5))
         })()`
      )
      return JSON.parse(raw)
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

function round(n) {
  return Math.round(n * 10) / 10
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
