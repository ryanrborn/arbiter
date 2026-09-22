// The nav rail's pin state and its document half, under `node --test`
// (bd-d63b1c).
//
// Pinned-or-not is a browser preference, stored in `localStorage` like the
// theme (`assets/js/theme.js`) and the session dock. That store can throw on
// read as well as on write, and an absent or unreadable value must read as
// unpinned. The rail's other half is `<html data-nav-rail>`, which is what
// `app.css` turns into `--nav-rail-page-inset`; and the below-`lg` overlay,
// which is `<html data-nav-rail-open>`.
//
//   node --test apps/arbiter_web/test/js/nav_rail_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import {
  NAV_RAIL_STORAGE_KEY,
  NavRail,
  applyPinned,
  applyStoredPin,
  readPinned,
  setOverlayOpen,
  writePinned
} from "../../assets/js/nav_rail.mjs"

function memoryStore(initial = {}) {
  const data = new Map(Object.entries(initial))
  return {
    data,
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
    removeItem: (k) => data.delete(k)
  }
}

const throwingStore = {
  getItem() {
    throw new Error("SecurityError")
  },
  setItem() {
    throw new Error("QuotaExceededError")
  },
  removeItem() {
    throw new Error("SecurityError")
  }
}

// Just enough of an element for the attribute writes the rail makes.
function fakeElement(attrs = {}) {
  const attributes = new Map(Object.entries(attrs))
  const listeners = new Map()
  return {
    attributes,
    dataset: new Proxy(
      {},
      {
        get: (_t, key) => attributes.get(`data-${kebab(key)}`),
        set: (_t, key, value) => {
          attributes.set(`data-${kebab(key)}`, String(value))
          return true
        },
        deleteProperty: (_t, key) => {
          attributes.delete(`data-${kebab(key)}`)
          return true
        }
      }
    ),
    getAttribute: (name) => (attributes.has(name) ? attributes.get(name) : null),
    setAttribute: (name, value) => attributes.set(name, String(value)),
    removeAttribute: (name) => attributes.delete(name),
    hasAttribute: (name) => attributes.has(name),
    addEventListener: (type, fn) => listeners.set(type, fn),
    removeEventListener: (type) => listeners.delete(type),
    listeners
  }
}

function kebab(key) {
  return key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)
}

test("absent, junk and unreadable values all read as unpinned", () => {
  assert.equal(readPinned(memoryStore()), false)
  assert.equal(readPinned(memoryStore({ [NAV_RAIL_STORAGE_KEY]: "yes please" })), false)
  assert.equal(readPinned(throwingStore), false)
  assert.equal(readPinned(null), false)
})

test("a stored pin reads back as pinned", () => {
  assert.equal(readPinned(memoryStore({ [NAV_RAIL_STORAGE_KEY]: "pinned" })), true)
})

test("writePinned round-trips and never throws on a broken store", () => {
  const store = memoryStore()

  writePinned(store, true)
  assert.equal(readPinned(store), true)

  writePinned(store, false)
  assert.equal(readPinned(store), false)
  assert.equal(store.data.has(NAV_RAIL_STORAGE_KEY), false)

  assert.doesNotThrow(() => writePinned(throwingStore, true))
  assert.doesNotThrow(() => writePinned(null, true))
})

test("applyPinned publishes the state on <html>, where app.css turns it into the inset", () => {
  const root = fakeElement()

  applyPinned(root, true)
  assert.equal(root.getAttribute("data-nav-rail"), "pinned")

  applyPinned(root, false)
  assert.equal(root.getAttribute("data-nav-rail"), "collapsed")
})

test("applyStoredPin sets the pin before first paint, and falls back to unpinned", () => {
  const pinnedDoc = { documentElement: fakeElement() }
  applyStoredPin(pinnedDoc, memoryStore({ [NAV_RAIL_STORAGE_KEY]: "pinned" }))
  assert.equal(pinnedDoc.documentElement.getAttribute("data-nav-rail"), "pinned")

  const brokenDoc = { documentElement: fakeElement() }
  assert.doesNotThrow(() => applyStoredPin(brokenDoc, throwingStore))
  assert.equal(brokenDoc.documentElement.getAttribute("data-nav-rail"), "collapsed")

  assert.doesNotThrow(() => applyStoredPin(null, memoryStore()))
})

test("setOverlayOpen toggles the below-lg overlay and its toggle's aria-expanded", () => {
  const root = fakeElement()
  const toggle = fakeElement({ "aria-expanded": "false" })

  setOverlayOpen(root, toggle, true)
  assert.equal(root.hasAttribute("data-nav-rail-open"), true)
  assert.equal(toggle.getAttribute("aria-expanded"), "true")

  setOverlayOpen(root, toggle, false)
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)
  assert.equal(toggle.getAttribute("aria-expanded"), "false")

  assert.doesNotThrow(() => setOverlayOpen(root, null, true))
})

// The hook, against a fake document. `mounted()` is where a pin survives a
// live navigation (the rail is re-rendered and the hook re-mounted) and where
// an overlay left open by the previous page gets closed.
function mountHook({ stored } = {}) {
  const root = fakeElement({ "data-nav-rail-open": "" })
  const toggle = fakeElement({ "aria-expanded": "true" })
  const pin = fakeElement({ "aria-pressed": "true" })
  const el = fakeElement()
  el.querySelector = (selector) => (selector === '[phx-click="toggle-nav-pin"]' ? pin : null)

  const store = memoryStore(stored ? { [NAV_RAIL_STORAGE_KEY]: stored } : {})
  const dispatched = []
  const win = {
    listeners: new Map(),
    addEventListener(type, fn) {
      this.listeners.set(type, fn)
    },
    removeEventListener(type) {
      this.listeners.delete(type)
    },
    dispatchEvent: (event) => dispatched.push(event.type)
  }
  const doc = {
    documentElement: root,
    getElementById: (id) => (id === "nav-rail-toggle" ? toggle : null)
  }

  const hook = Object.create(NavRail)
  hook.el = el
  hook.env = { doc, win, store }
  hook.mounted()

  return { hook, root, toggle, pin, el, store, win, dispatched }
}

test("mounting restores the stored pin, closes a stale overlay and reports aria-pressed", () => {
  const { root, toggle, pin } = mountHook({ stored: "pinned" })

  assert.equal(root.getAttribute("data-nav-rail"), "pinned")
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)
  assert.equal(toggle.getAttribute("aria-expanded"), "false")
  assert.equal(pin.getAttribute("aria-pressed"), "true")

  const unpinned = mountHook()
  assert.equal(unpinned.root.getAttribute("data-nav-rail"), "collapsed")
  assert.equal(unpinned.pin.getAttribute("aria-pressed"), "false")
})

function click(el, target) {
  let stopped = false
  let prevented = false
  el.listeners.get("click")({
    target,
    stopPropagation: () => (stopped = true),
    preventDefault: () => (prevented = true)
  })
  return { stopped, prevented }
}

test("the pin button toggles and persists the pin without reaching the server", () => {
  const { el, root, pin, store, dispatched } = mountHook()
  const pinTarget = { closest: (sel) => (sel === '[phx-click="toggle-nav-pin"]' ? pin : null) }

  const first = click(el, pinTarget)
  // Stopped here, so LiveView's window-level click binding never pushes
  // `toggle-nav-pin` to a LiveView that has no handler for it.
  assert.equal(first.stopped, true)
  assert.equal(root.getAttribute("data-nav-rail"), "pinned")
  assert.equal(pin.getAttribute("aria-pressed"), "true")
  assert.equal(readPinned(store), true)
  // The dock re-decides whether a side panel still fits the narrower page.
  assert.deepEqual(dispatched, ["resize"])

  click(el, pinTarget)
  assert.equal(root.getAttribute("data-nav-rail"), "collapsed")
  assert.equal(pin.getAttribute("aria-pressed"), "false")
  assert.equal(readPinned(store), false)
})

test("following any rail link closes the overlay", () => {
  const { el, root, hook } = mountHook()
  hook.env.win.listeners.get("nav-rail:open")()
  assert.equal(root.hasAttribute("data-nav-rail-open"), true)

  const link = { closest: (sel) => (sel === "a[href]" ? {} : null) }
  const result = click(el, link)

  assert.equal(result.stopped, false)
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)
})

test("the hamburger and backdrop events open, toggle and close the overlay", () => {
  const { root, toggle, win } = mountHook()

  win.listeners.get("nav-rail:toggle")()
  assert.equal(root.hasAttribute("data-nav-rail-open"), true)
  assert.equal(toggle.getAttribute("aria-expanded"), "true")

  win.listeners.get("nav-rail:toggle")()
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)

  win.listeners.get("nav-rail:open")()
  win.listeners.get("nav-rail:close")()
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)

  win.listeners.get("nav-rail:open")()
  win.listeners.get("keydown")({ key: "Escape" })
  assert.equal(root.hasAttribute("data-nav-rail-open"), false)
})

test("a pin made in another tab is picked up", () => {
  const { root, pin, win } = mountHook()

  win.listeners.get("storage")({ key: NAV_RAIL_STORAGE_KEY, newValue: "pinned" })
  assert.equal(root.getAttribute("data-nav-rail"), "pinned")
  assert.equal(pin.getAttribute("aria-pressed"), "true")

  win.listeners.get("storage")({ key: "phx:theme", newValue: "dark" })
  assert.equal(root.getAttribute("data-nav-rail"), "pinned")
})

test("a server patch that resets aria-pressed is corrected in updated()", () => {
  const { hook, pin } = mountHook()
  pin.setAttribute("aria-pressed", "true")

  hook.updated()
  assert.equal(pin.getAttribute("aria-pressed"), "false")
})

test("destroyed() unbinds every window listener it added", () => {
  const { hook, win } = mountHook()
  assert.ok(win.listeners.size > 0)

  hook.destroyed()
  assert.equal(win.listeners.size, 0)
})
