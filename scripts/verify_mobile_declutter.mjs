#!/usr/bin/env node
//
// bd-9inpfa — the Sessions list header and the Workspace detail page at
// phone widths, in a real browser.
//
// `ArbiterWeb.CoreComponents.DomainTest`, `ArbiterWeb.SessionIndexLiveTest`
// and `ArbiterWeb.WorkspaceConfigScreenTest` prove the markup carries the
// right responsive classes. None of them has a layout engine, so none can
// prove the thing the acceptance criteria actually ask for: that the page
// has no horizontal scroll at 375/414px, in light and dark, and that 1280px
// still renders the way it always did.
//
//   node scripts/verify_mobile_declutter.mjs --url http://127.0.0.1:4848 \
//     --session <session id> --workspace-id <workspace id> [--shots <dir>]
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser). `--shots <dir>`
// also writes a full-page PNG per page/viewport/theme for a human to look at.
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
const WORKSPACE_ID = options["workspace-id"] || null

// The two phone widths the ticket names, and the desktop width its "no
// regression" criterion is checked against.
const PHONE_375 = 375
const PHONE_414 = 414
const DESKTOP = 1280
const HEIGHT = 1400

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-mobile-declutter-"))
const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    `--window-size=${DESKTOP},${HEIGHT}`,
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

function stateScript() {
  return `(() => {
  return JSON.stringify({
    pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    width: window.innerWidth,
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

async function screenshot(cdp, sessionId, name) {
  if (!SHOTS) return
  const { data } = await cdp.send(
    "Page.captureScreenshot",
    { format: "png", captureBeyondViewport: true },
    sessionId
  )
  writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"))
}

async function checkPage(page, cdp, sessionId, { name, url, selector }) {
  for (const width of [PHONE_375, PHONE_414, DESKTOP]) {
    for (const theme of ["light", "dark"]) {
      const tag = `${name} ${width}px/${theme}`
      await page.resizeViewport(width, HEIGHT)
      await page.goto(`${BASE}${url}`)
      await joined(page, tag, selector)
      await page.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
      await page.settle()
      const s = await state(page)

      check(`${tag} no horizontal overflow`, s.pageOverflow <= 0, `${s.pageOverflow}px beyond a ${s.width}px viewport`)
      check(`${tag} page healthy`, !s.errored, `phx-error present: ${s.errored}`)

      await screenshot(cdp, sessionId, `${name}-${width}-${theme}`)
    }
  }
}

async function run(page, cdp, sessionId) {
  await checkPage(page, cdp, sessionId, {
    name: "sessions",
    url: "/sessions",
    selector: "#sessions-list, #sessions-empty"
  })

  if (WORKSPACE_ID) {
    await checkPage(page, cdp, sessionId, {
      name: "workspace",
      url: `/workspaces/${WORKSPACE_ID}`,
      selector: "#ws-rail"
    })

    // The Policy pane specifically: at ~20 settings it is the densest
    // section on the page, and the one the mobile disclosure grouping
    // (`Rows.mobile_group/1`) exists for.
    for (const width of [PHONE_375, DESKTOP]) {
      for (const theme of ["light", "dark"]) {
        await page.resizeViewport(width, HEIGHT)
        await page.goto(`${BASE}/workspaces/${WORKSPACE_ID}`)
        await joined(page, `workspace policy ${width}px/${theme}`, "#ws-rail")
        await page.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
        await page.eval(
          `document.querySelector('#ws-rail button[phx-value-section="policy"]').click()`
        )
        await page.settle()
        const s = await state(page)
        check(
          `workspace policy pane ${width}px/${theme} no horizontal overflow`,
          s.pageOverflow <= 0,
          `${s.pageOverflow}px beyond a ${s.width}px viewport`
        )

        const groupsShown = await page.eval(`(() => {
          const summaries = [...document.querySelectorAll("#ws-rail ~ div summary")]
          return summaries.length > 0 && summaries.every((el) => getComputedStyle(el).display !== "none")
        })()`)
        check(
          `workspace policy pane ${width}px/${theme} disclosure headings ${width === PHONE_375 ? "shown" : "hidden"}`,
          width === PHONE_375 ? groupsShown : !groupsShown,
          `summaries visible: ${groupsShown}`
        )

        await screenshot(cdp, sessionId, `workspace-policy-${width}-${theme}`)
      }
    }
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

    async resizeViewport(width, height) {
      await cdp.send(
        "Emulation.setDeviceMetricsOverride",
        { width, height, deviceScaleFactor: 1, mobile: width < DESKTOP },
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
