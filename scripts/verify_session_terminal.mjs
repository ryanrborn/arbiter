#!/usr/bin/env node
//
// bd-c76fu9, phase 5 acceptance criteria 2, 5 and 6 — the checks that need a
// real browser and nothing else.
//
// `mix test` can prove the page chrome, the channel and the resume protocol.
// It cannot prove that the *vendored* xterm and the **canvas** addon construct
// together at the versions in `assets/vendor/xterm/`, that a `Uint8Array`
// write renders, that a UTF-8 character split across two frames is reassembled
// instead of corrupted, or that §6.3's `Ctrl/Cmd+Shift+C/V` bindings work
// while plain `Ctrl+C` still reaches the agent as SIGINT. Those are renderer
// and keyboard claims, and a headless Chromium is the only honest way to make
// them.
//
//   node scripts/verify_session_terminal.mjs
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim and a
// final `RESULT: PASS|FAIL`. `ArbiterWeb.SessionTerminalBrowserTest` runs this
// as part of `mix test` wherever a Chromium and an esbuild are on disk.
//
// No npm, as everywhere else in this repo (RFC §6.1): esbuild is the binary
// the `esbuild` Mix package already installed, the browser is one already on
// the machine, and the driver is the Chrome DevTools Protocol over Node's
// built-in `WebSocket` and `fetch`.

import { spawn } from "node:child_process"
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, "..")
const ASSETS = path.join(ROOT, "apps/arbiter_web/assets")
const PROBE = path.join(ROOT, "apps/arbiter_web/test/js/terminal_probe.mjs")

const CHROME_CANDIDATES = [
  process.env.ARB_CHROME,
  path.join(
    process.env.HOME || "",
    ".cache/ms-playwright/chromium-1234/chrome-linux64/chrome"
  ),
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome"
].filter(Boolean)

const ESBUILD_CANDIDATES = [
  process.env.ARB_ESBUILD,
  path.join(ROOT, "_build/esbuild-linux-x64"),
  path.join(process.env.HOME || "", ".cache/phx-esbuild/package/bin/esbuild")
].filter(Boolean)

function firstExisting(candidates, what) {
  const found = candidates.find((c) => existsSync(c))
  if (!found) {
    console.error(`RESULT: SKIP — no ${what} found (looked in ${candidates.join(", ")})`)
    process.exit(3)
  }
  return found
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], ...options })
    let out = ""
    child.stdout.on("data", (d) => (out += d))
    child.stderr.on("data", (d) => (out += d))
    child.on("error", reject)
    child.on("exit", (code) => (code === 0 ? resolve(out) : reject(new Error(out))))
  })
}

// -- 1. bundle the probe ------------------------------------------------------

const work = mkdtempSync(path.join(tmpdir(), "arb-terminal-probe-"))
const bundle = path.join(work, "probe.js")
const page = path.join(work, "probe.html")

const esbuild = firstExisting(ESBUILD_CANDIDATES, "esbuild binary")
const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")

await run(
  esbuild,
  [
    PROBE,
    "--bundle",
    "--format=iife",
    "--target=es2022",
    `--outfile=${bundle}`,
    // The same alias and module resolution `config/config.exs` gives the app
    // bundle, so the probe loads exactly the files the dashboard ships.
    "--alias:@=.",
    "--log-level=warning"
  ],
  { cwd: ASSETS, env: { ...process.env, NODE_PATH: path.join(ROOT, "deps") } }
)

writeFileSync(
  page,
  `<!doctype html>
<meta charset="utf-8">
<link rel="stylesheet" href="${path.join(ASSETS, "css/xterm.css")}">
<style>
  body { margin: 0; background: #16181d }
  /* Mirrors how app.css defines the terminal palette: custom properties that
     the data-theme attribute on <html> re-resolves. The canvas renderer holds
     a resolved palette, so the hook has to notice. */
  :root { --arb-term-bg: #ffffff; --arb-term-fg: #1f2430 }
  [data-theme="dark"] { --arb-term-bg: #16181d; --arb-term-fg: #d6dae2 }
</style>
<div id="terminal"></div>
<script src="${bundle}"></script>
`
)

// -- 2. drive a headless Chromium over the DevTools Protocol -----------------

const profile = path.join(work, "profile")

const browser = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-first-run",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank"
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
)

let failed = false

try {
  const port = await waitForDevToolsPort(path.join(profile, "DevToolsActivePort"))
  const { webSocketDebuggerUrl } = await (
    await fetch(`http://127.0.0.1:${port}/json/version`)
  ).json()

  const cdp = await connect(webSocketDebuggerUrl)

  const { targetId } = await cdp.send("Target.createTarget", { url: `file://${page}` })
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true })

  await cdp.send("Runtime.enable", {}, sessionId)

  await poll(
    () => evaluate(cdp, sessionId, "typeof window.__arbProbe === 'function'"),
    "the probe bundle never loaded"
  )

  const result = await evaluate(
    cdp,
    sessionId,
    "window.__arbProbe(document.getElementById('terminal'))",
    true
  )

  for (const c of result.checks) {
    if (!c.ok) failed = true
    console.log(`CHECK ${c.name}: ${c.ok ? "PASS" : "FAIL"} — ${c.detail}`)
  }

  if (result.checks.length === 0) {
    failed = true
    console.log("CHECK probe: FAIL — the probe reported no checks at all")
  }

  cdp.close()
} catch (error) {
  failed = true
  console.log(`CHECK harness: FAIL — ${(error && error.message) || error}`)
} finally {
  // Exact-PID teardown only. Never a pattern-matching kill: this repo has an
  // incident class around one reaching the live coordinator.
  browser.kill("SIGTERM")
  rmSync(work, { recursive: true, force: true })
}

console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- helpers ------------------------------------------------------------------

async function waitForDevToolsPort(file) {
  for (let i = 0; i < 100; i++) {
    if (existsSync(file)) {
      const port = readFileSync(file, "utf8").split("\n")[0].trim()
      if (port) return port
    }
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error("the browser never wrote a DevToolsActivePort")
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    let nextId = 0
    const pending = new Map()

    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data)
      const waiter = pending.get(message.id)
      if (!waiter) return
      pending.delete(message.id)
      message.error ? waiter.reject(new Error(JSON.stringify(message.error))) : waiter.resolve(message.result)
    })

    ws.addEventListener("error", (event) => reject(new Error(`devtools socket: ${event.message || "error"}`)))

    ws.addEventListener("open", () =>
      resolve({
        send(method, params = {}, sessionId) {
          const id = ++nextId
          const frame = { id, method, params }
          if (sessionId) frame.sessionId = sessionId
          ws.send(JSON.stringify(frame))
          return new Promise((res, rej) => pending.set(id, { resolve: res, reject: rej }))
        },
        close: () => ws.close()
      })
    )
  })
}

async function evaluate(cdp, sessionId, expression, awaitPromise = false) {
  const { result, exceptionDetails } = await cdp.send(
    "Runtime.evaluate",
    { expression, returnByValue: true, awaitPromise },
    sessionId
  )

  if (exceptionDetails) {
    throw new Error(
      (exceptionDetails.exception && exceptionDetails.exception.description) ||
        exceptionDetails.text
    )
  }

  return result.value
}

async function poll(fn, message, attempts = 100) {
  for (let i = 0; i < attempts; i++) {
    if (await fn()) return
    await new Promise((r) => setTimeout(r, 100))
  }
  throw new Error(message)
}
