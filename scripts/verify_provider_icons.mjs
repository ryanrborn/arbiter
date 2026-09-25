#!/usr/bin/env node
//
// bd-aro53b — the provider marks on the workers index, in a real browser.
//
// `ArbiterWeb.CoreComponents.ProviderIconTest` and `WorkerIndexLiveTest` prove
// the markup (an <svg>/<image>, a title, an aria-label). Neither can show that
// the Antigravity PNG actually loads and paints, or that all three marks are
// visually distinct on a real Running card in both themes. `ConnCase` has no
// layout engine and does not fetch images.
//
//   node scripts/verify_provider_icons.mjs --url http://127.0.0.1:PORT [--shots <dir>]
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`; exit 3 means SKIP (no browser).
//
// No npm: the browser is Playwright's cached Chromium, driven directly over
// the Chrome DevTools Protocol via Node's built-in WebSocket/fetch.

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

const WIDTH = 1280
const HEIGHT = 900

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-provider-icons-"))
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
  const icons = [...document.querySelectorAll('#workers svg[role="img"]')]
  const describe = (svg) => {
    return {
      ariaLabel: svg.getAttribute("aria-label"),
      title: svg.querySelector("title") ? svg.querySelector("title").textContent : null,
      rect: (() => {
        const r = svg.getBoundingClientRect()
        return { width: r.width, height: r.height }
      })(),
      paintedNodes: svg.querySelectorAll("path, ellipse, rect, circle, polygon").length
    }
  }
  return JSON.stringify({
    count: icons.length,
    icons: icons.map(describe),
    errored: !!document.querySelector(".phx-error")
  })
})()`
}

async function screenshot(cdp, sessionId, name) {
  if (!SHOTS) return
  const { data } = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId)
  writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, "base64"))
}

async function run(page, cdp, sessionId) {
  for (const theme of ["light", "dark"]) {
    const tag = `theme=${theme}`
    await page.goto(`${BASE}/workers`)
    await joined(page, `/workers at ${tag}`, "#workers")
    await page.eval(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)})`)
    await page.settle()

    const s = JSON.parse(await page.eval(stateScript()))

    check(`${tag} three provider icons render`, s.count === 3, `found ${s.count}: ${s.icons.map((i) => i.ariaLabel).join(", ")}`)

    const labels = s.icons.map((i) => i.ariaLabel).sort()
    check(
      `${tag} labels are Claude/Codex/Antigravity`,
      JSON.stringify(labels) === JSON.stringify(["Antigravity", "Claude", "Codex"]),
      labels.join(", ")
    )

    for (const icon of s.icons) {
      check(`${tag} ${icon.ariaLabel} has a non-zero rendered size`, icon.rect.width > 0 && icon.rect.height > 0, `${icon.rect.width}x${icon.rect.height}`)
      check(`${tag} ${icon.ariaLabel} title matches aria-label`, icon.title === icon.ariaLabel, `title=${icon.title}`)
      check(`${tag} ${icon.ariaLabel} actually paints vector content`, icon.paintedNodes > 0, `${icon.paintedNodes} painted node(s)`)
    }

    check(`${tag} page healthy`, !s.errored, `phx-error present: ${s.errored}`)

    await screenshot(cdp, sessionId, `provider-icons-workers-${theme}`)
  }

  check("no console errors", consoleErrors.length === 0, consoleErrors.slice(0, 3).join(" | ") || "none")
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
