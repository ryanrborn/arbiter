#!/usr/bin/env node
//
// bd-3r2otb — the four live-verification claims, driven through a real
// browser against a running dashboard.
//
// `scripts/verify_session_terminal.mjs` drives `createSessionTerminal` on a
// bare `file://` page: it proves the renderer and the protocol engine. What it
// cannot see is everything that only exists on the *dashboard*: the hook
// mounting when a session is launched, the `/session` socket it opens, the
// pane's real layout inside the page's chrome, and what happens when the
// session is killed underneath it. Every bug in this ticket lived in exactly
// that gap — the terminal's own unit tests were green while the page was
// stuck on "connecting…".
//
// Since bd-9myzv8 the terminal itself lives in the **session dock**, and since
// bd-a292yj there is no `/sessions/<id>` to navigate to at all: clicking
// Launch on `/sessions` opens the session's window in the dock, on the page
// the operator is already on. So these four criteria are measured against that
// window — it has to reach `live`, fit, honour the copy/paste bindings and go
// read-only on a kill. The claims are unchanged; only the pane they are made
// about moved.
//
//   node scripts/verify_session_page.mjs --url http://127.0.0.1:4848
//
// Output is one `CHECK <name>: PASS|FAIL — <detail>` line per claim, a
// `SESSION <id>` line naming the session it launched (so a caller can assert
// against the server side of it), and a final `RESULT: PASS|FAIL`.
// `ArbiterWeb.SessionPageBrowserTest` runs it against a Bandit listener as
// part of `mix test`; the coordinator runs it against the live host for the
// post-merge criterion.
//
// No npm (RFC §6.1): the browser is one already on the machine and the driver
// is the Chrome DevTools Protocol over Node's built-in `WebSocket` and
// `fetch`.

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
const PASTE = "pasted-through-the-browser"

// Ctrl is 2 and Shift is 8 in the DevTools Protocol's modifier bitmask.
const CTRL = 2
const SHIFT = 8

const checks = []
const consoleErrors = []

function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail })
  console.log(`CHECK ${name}: ${ok ? "PASS" : "FAIL"} — ${detail}`)
}

const chrome = firstExisting(CHROME_CANDIDATES, "Chromium/Chrome binary")
const work = mkdtempSync(path.join(tmpdir(), "arb-session-page-"))
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

  // The clipboard is half of criterion 3, and a headless browser will not
  // prompt for it.
  await cdp.send("Browser.grantPermissions", {
    origin: BASE,
    permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"]
  })

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
} catch (error) {
  check("harness", false, (error && error.stack) || String(error))
} finally {
  if (cdp) cdp.close()
  // Exact-PID teardown only. This repo has an incident class around
  // pattern-matching kills reaching the live coordinator.
  browser.kill("SIGTERM")
  rmSync(work, { recursive: true, force: true })
}

const failed = checks.length === 0 || checks.some((c) => !c.ok)
console.log(`RESULT: ${failed ? "FAIL" : "PASS"}`)
process.exit(failed ? 1 : 0)

// -- the run ------------------------------------------------------------------

async function run(page) {
  await page.goto(`${BASE}/sessions`)
  // `isConnected()` reports the *socket*, not the root LiveView: between the
  // socket opening and the view's join reply landing there is a window where
  // the button exists but no view owns its `phx-click`, and a click fired
  // there is dropped silently. `phx-connected` is set in `hideLoader()`, off
  // the join reply, so it is the earliest point a click is guaranteed to be
  // routed.
  await page.poll(
    `(() => {
       if (!window.liveSocket || !window.liveSocket.isConnected()) return false
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected")
     })()`,
    "the dashboard's root LiveView never joined"
  )

  // A marker that only a *full page load* can clear. Criterion 1 is about
  // reaching a live terminal without one: if the browser reloaded, the bug
  // would hide.
  await page.eval("window.__arbNoReload = true")

  // Every keydown that our handler does not stop reaches the document. This is
  // how criterion 3's "never reaches the browser" is observed: a trusted
  // Ctrl+Shift+C whose default was prevented is one the browser will not act
  // on.
  await page.eval(`
    window.__arbKeys = []
    document.addEventListener("keydown", (e) => {
      window.__arbKeys.push({
        key: e.key,
        ctrl: e.ctrlKey,
        shift: e.shiftKey,
        prevented: e.defaultPrevented
      })
    })
  `)

  // Clicked exactly once, then polled. The in-flight markers
  // (`data-phx-ref-src`, `phx-click-loading`) do *not* bound this wait: they
  // clear when the reply to `launch` is applied, and since phase 3 that reply
  // is a `push_event` rather than the old `push_navigate`, so the window only
  // appears a further round trip later (client → `session-dock:open` → the
  // dock's own LiveView → `open`). In that gap the button is idle and there is
  // no window yet, so a re-clicking poll launches a *second real session*
  // whose window then steals the expanded slot — which is what made this check
  // fail ~40% of the time (bd-a292yj review, finding 1).
  const sessionId = await page.pollValue(
    `(() => {
       const window_ = document.querySelector('[id^="session-dock-window-"]')
       if (window_) return window_.id.replace("session-dock-window-", "")

       const button = document.getElementById("launch-session")
       if (button && !window.__arbLaunchClicked) {
         window.__arbLaunchClicked = true
         button.click()
       }
       return null
     })()`,
    "the launch never opened a session window in the dock"
  )
  console.log(`SESSION ${sessionId}`)

  // -- criterion 1: the first join after the launch redirect ------------------
  //
  // `/sessions` holds no terminal: Launch pushes `session-dock:open` and the
  // *dock* is what connects (bd-9myzv8, bd-a292yj). So the window has to
  // appear before there is a status strip to read at all.
  await page.poll(
    `!!document.getElementById("session-dock-window-${sessionId}")`,
    "the launch never handed the session to the dock"
  )

  let state = null
  try {
    state = await page.pollValue(
      `(() => {
         const el = document.querySelector('[id^="session-dock-status-"]')
         return el && el.dataset.state === "live" ? "live" : null
       })()`,
      "never reached live"
    )
  } catch (_error) {
    state = await page.eval(
      `(() => {
         const el = document.querySelector('[id^="session-dock-status-"]')
         if (!el) return "(no status strip)"
         return el.dataset.state || "(hook never painted a state)"
       })()`
    )
  }

  const noReload = await page.eval("window.__arbNoReload === true")

  check(
    "launch-reaches-live-without-a-reload",
    state === "live" && noReload,
    `status=${state} live-navigation=${noReload}` +
      (consoleErrors.length ? ` console=${JSON.stringify(consoleErrors.slice(0, 2))}` : "")
  )

  check(
    "no-console-errors",
    consoleErrors.length === 0,
    consoleErrors.length ? JSON.stringify(consoleErrors.slice(0, 3)) : "the page logged none"
  )

  if (state !== "live") return

  // -- a LiveView-only rejoin must not false-flag a stall ---------------------
  //
  // Dropping the *LiveView* socket re-runs `mount/3`: `terminal_live?` is back
  // to false and a fresh stall check is armed. The terminal's own `/session`
  // socket stays up, so nothing on the channel changes and only the hook's
  // `reconnected()` can re-announce the state. The verdict is taken further
  // down, once the server's 8s stall window has elapsed.
  await page.eval(`
    window.__arbRejoined = false
    window.liveSocket.disconnect(() => {
      window.__arbRejoined = true
      window.liveSocket.connect()
    })
  `)
  await page.poll("window.__arbRejoined === true", "the LiveView socket never dropped")
  await page.poll(
    `(() => {
       const main = document.querySelector("[data-phx-main]")
       return !!main && main.classList.contains("phx-connected")
     })()`,
    "the LiveView never rejoined"
  )
  const rejoinedAt = Date.now()

  // -- criterion 2: every fitted row is actually visible ----------------------

  await page.settle()
  check(...(await fitCheck(page, "last-row-is-fully-visible")))

  await page.resizeViewport(1100, 700)
  await page.settle(800)
  check(...(await fitCheck(page, "last-row-is-fully-visible-after-a-resize")))

  await page.resizeViewport(1600, 1000)
  await page.settle(800)
  check(...(await fitCheck(page, "last-row-is-fully-visible-when-grown")))

  // -- criterion 3: the copy/paste bindings -----------------------------------

  await page.focusTerminal()

  await page.eval(`navigator.clipboard.writeText(${JSON.stringify(PASTE)})`, true)

  await page.eval("window.__arbKeys = []")
  await page.key("c", 67, CTRL | SHIFT)
  await page.settle(200)

  const copy = await page.eval(
    `JSON.stringify((window.__arbKeys || []).filter((k) => k.ctrl && k.shift))`
  )
  const copyKeys = JSON.parse(copy)
  check(
    "ctrl-shift-c-never-reaches-the-browser",
    copyKeys.length > 0 && copyKeys.every((k) => k.prevented),
    `document saw ${copy}`
  )

  await page.eval("window.__arbKeys = []")
  await page.key("v", 86, CTRL | SHIFT)
  await page.settle(400)

  const paste = await page.eval(
    `JSON.stringify((window.__arbKeys || []).filter((k) => k.ctrl && k.shift))`
  )
  check(
    "ctrl-shift-v-reaches-the-hook",
    JSON.parse(paste).length > 0,
    `document saw ${paste} (the pane's bytes are asserted server-side)`
  )

  // -- the deferred verdict on the rejoin's stall banner ----------------------
  //
  // `@stall_ms` is 8s from the rejoin's `mount/3`. The checks above have
  // already burned part of it; wait out the rest plus a margin, then the
  // banner is either there or it never will be.
  await page.settle(Math.max(0, rejoinedAt + 9_500 - Date.now()))

  const afterStall = await page.eval(
    `(() => {
       const stalled = !!document.querySelector('[id^="session-dock-stalled-"]')
       const el = document.querySelector('[id^="session-dock-status-"]')
       return JSON.stringify({ stalled, state: el && el.dataset.state })
     })()`
  )
  const stallVerdict = JSON.parse(afterStall)

  check(
    "a-liveview-rejoin-does-not-claim-the-terminal-stalled",
    !stallVerdict.stalled && stallVerdict.state === "live",
    `stall banner=${stallVerdict.stalled} status=${stallVerdict.state}`
  )

  // -- criterion 4: kill leaves a read-only window, live ----------------------
  //
  // Phase 3 (bd-a292yj) changed the *shape* of this claim rather than the
  // claim: killing used to replace the pane with a placeholder, and now leaves
  // it exactly where it was, read-only, with its final scrollback and the end
  // reason — until the operator dismisses it. Both halves are checked, because
  // "the pane is still there" and "the pane is dead" have to be true at once.

  // A line only this check could have put there. The claim is about the
  // *buffer* surviving, and whether the scripted pane happens to echo anything
  // is not what is under test.
  await page.eval(
    `document.getElementById("session-dock-terminal-${sessionId}")
       .__arbTerminal.term.write("ARB-SCROLLBACK-MARKER\\r\\n")`
  )

  await page.eval(`document.getElementById("session-dock-menu-${sessionId}").click()`)
  await page.poll(
    `!!document.getElementById("session-dock-kill-${sessionId}")`,
    "the window's overflow never opened"
  )
  await page.eval(`document.getElementById("session-dock-kill-${sessionId}").click()`)
  await page.poll(`!!document.getElementById("confirm-kill")`, "the kill modal never opened")
  await page.eval(`document.getElementById("confirm-kill").click()`)

  let killed = null
  try {
    killed = await page.pollValue(
      `(() => {
         const pane = document.getElementById("session-dock-terminal-${sessionId}")
         const ended = !!document.getElementById("session-dock-ended-${sessionId}")
         if (!pane || !ended) return null
         const term = pane.__arbTerminal
         if (!term || !term.readOnly()) return null
         // The scrollback is the whole reason the window stays. An empty
         // buffer would pass every other check here and still be the bug.
         return term.snapshot().includes("ARB-SCROLLBACK-MARKER") ? "read-only" : null
       })()`,
      "the pane never went read-only with its scrollback intact"
    )
  } catch (_error) {
    killed = await page.eval(
      `(() => {
         const win = document.getElementById("session-dock-window-${sessionId}")
         const ids = win
           ? Array.from(win.querySelectorAll("[id]")).map((e) => e.id).join(",")
           : "(no window)"
         const pane = document.getElementById("session-dock-terminal-${sessionId}")
         if (!pane) return "the pane was torn down; ids=" + ids
         const term = pane.__arbTerminal
         if (!term) return "the pane has no terminal; ids=" + ids
         return "still writable, readOnly=" + term.readOnly() + "; ids=" + ids
       })()`
    )
  }

  const stillLive = await page.eval("window.__arbNoReload === true")

  check(
    "kill-leaves-a-read-only-window-without-a-reload",
    killed === "read-only" && stillLive,
    `${killed} live-navigation=${stillLive}`
  )

  // -- the frozen window survives a LiveView rejoin ---------------------------
  //
  // A rejoin re-runs the dock's `mount/3`, which re-renders it empty before
  // `restore` puts the windows back — so every window element, and every
  // xterm in one, is destroyed and rebuilt. A live pane recovers by replaying
  // its stream; a dead one has no stream left, and without the client keeping
  // both the fact that it is frozen and the text it held, the operator's
  // ended window would quietly become "its output is unavailable".

  // The pane that is about to be destroyed is branded first, so the poll below
  // cannot be satisfied by it. Without this the check races the wipe: a first
  // tick that lands before the dock's post-rejoin re-render sees the *old*
  // element, still read-only and still holding the marker, and passes without
  // the rebuild ever having happened.
  await page.eval(
    `document.getElementById("session-dock-terminal-${sessionId}").dataset.arbPreRejoin = "1"`
  )

  await page.eval(`
    window.__arbRejoined2 = false
    window.liveSocket.disconnect(() => {
      window.__arbRejoined2 = true
      window.liveSocket.connect()
    })
  `)
  await page.poll("window.__arbRejoined2 === true", "the LiveView socket never dropped again")

  let survived = null
  try {
    survived = await page.pollValue(
      `(() => {
         const pane = document.getElementById("session-dock-terminal-${sessionId}")
         if (!pane || pane.dataset.arbPreRejoin) return null
         const term = pane.__arbTerminal
         if (!term || !term.readOnly()) return null
         return term.snapshot().includes("ARB-SCROLLBACK-MARKER") ? "survived" : null
       })()`,
      "the frozen window did not come back read-only with its scrollback"
    )
  } catch (_error) {
    survived = await page.eval(
      `(() => {
         if (document.getElementById("session-dock-unavailable-${sessionId}")) {
           return "downgraded to 'output unavailable'"
         }
         const pane = document.getElementById("session-dock-terminal-${sessionId}")
         if (!pane) return "the window came back without a pane"
         const term = pane.__arbTerminal
         if (!term) return "the pane came back without a terminal"
         return term.readOnly() ? "read-only but empty" : "came back writable"
       })()`
    )
  }

  check(
    "a-frozen-window-survives-a-liveview-rejoin",
    survived === "survived",
    `${survived}`
  )

  // ...and dismissing it is the one thing that takes it away.
  //
  // Clicked from inside the poll rather than once up front. This lands right
  // after a rejoin, and a `phx-click` on a view that has not finished joining
  // is dropped on the floor by LiveView with no sign of it — so the click is
  // re-issued until the window goes. Dismiss is idempotent and view-only, so
  // repeating it is free (unlike Launch above). `__arbDismissClicked` is what
  // keeps this honest: an absent window only counts as "gone" once this check
  // has actually clicked something, never because the DOM happened to be
  // mid-rebuild on the first tick.
  let dismissed = null
  try {
    dismissed = await page.pollValue(
      `(() => {
         const win = document.getElementById("session-dock-window-${sessionId}")
         if (!win) return window.__arbDismissClicked ? "gone" : null

         const button = document.getElementById("session-dock-dismiss-${sessionId}")
         if (button) {
           window.__arbDismissClicked = true
           button.click()
         }
         return null
       })()`,
      "the dismissed window stayed in the dock"
    )
  } catch (_error) {
    dismissed = "still docked"
  }

  check(
    "dismissing-an-ended-window-removes-it",
    dismissed === "gone",
    `${dismissed}`
  )
}

// The dock pane's box is `h-[min(52vh,380px)]` of frame minus the status strip,
// with `p-1.5` of its own, so "the last row is visible" is exactly "xterm's
// screen ends inside the container's content box". A fraction over is what
// clips half of Claude Code's footer.
async function fitCheck(page, name) {
  const measured = await page.eval(
    `(() => {
       const pane = document.querySelector('[id^="session-dock-terminal-"]')
       if (!pane) return { error: "no terminal element" }
       const screen = pane.querySelector(".xterm-screen")
       if (!screen) return { error: "no .xterm-screen" }

       const style = getComputedStyle(pane)
       const box = pane.getBoundingClientRect()
       const contentBottom =
         box.bottom - parseFloat(style.paddingBottom) - parseFloat(style.borderBottomWidth)
       const contentTop =
         box.top + parseFloat(style.paddingTop) + parseFloat(style.borderTopWidth)

       // The status strip's meta slot is the server's own view of the pane
       // geometry, so it needs no handle on the xterm instance to report the
       // row count the fit actually asked for.
       const meta = document.querySelector('[id^="session-dock-status-"] [data-role="meta"]')

       return {
         overflow: screen.getBoundingClientRect().bottom - contentBottom,
         screenHeight: screen.getBoundingClientRect().height,
         contentHeight: contentBottom - contentTop,
         paneHeight: box.height,
         geometry: meta ? meta.textContent.trim() : "(none)"
       }
     })()`
  )

  if (measured.error) return [name, false, measured.error]

  // Sub-pixel: a fitted row can land a hair over on a fractional device ratio
  // and still render whole.
  const ok = measured.overflow <= 0.5

  return [
    name,
    ok,
    `screen ${round(measured.screenHeight)}px in a ${round(measured.contentHeight)}px content box ` +
      `(pane ${round(measured.paneHeight)}px, pane geometry ${measured.geometry}) — ` +
      `overflow ${round(measured.overflow)}px`
  ]
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
    },

    // Click in the middle of the pane, the way an operator focuses a terminal.
    async focusTerminal() {
      const box = await driver.eval(
        `(() => {
           const pane = document.querySelector('[id^="session-dock-terminal-"]')
           if (!pane) return null
           const r = pane.getBoundingClientRect()
           return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
         })()`
      )
      if (!box) return

      for (const type of ["mousePressed", "mouseReleased"]) {
        await cdp.send(
          "Input.dispatchMouseEvent",
          { type, x: box.x, y: box.y, button: "left", clickCount: 1 },
          sessionId
        )
      }
      await sleep(100)
    },

    // A *trusted* key event — the only kind that can prove the handler stops
    // the browser's own binding.
    async key(char, keyCode, modifiers) {
      const base = {
        modifiers,
        key: modifiers & SHIFT ? char.toUpperCase() : char,
        code: `Key${char.toUpperCase()}`,
        windowsVirtualKeyCode: keyCode,
        nativeVirtualKeyCode: keyCode
      }

      await cdp.send("Input.dispatchKeyEvent", { ...base, type: "rawKeyDown" }, sessionId)
      await cdp.send("Input.dispatchKeyEvent", { ...base, type: "keyUp" }, sessionId)
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
