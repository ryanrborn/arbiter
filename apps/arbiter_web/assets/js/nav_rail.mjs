// The nav rail's client half (bd-d63b1c): whether the rail is pinned open,
// and the below-`lg` overlay.
//
// Pinned-or-not is a *browser* preference, the same kind of thing as the
// theme (`theme.js`) and the session dock's open windows, so it lives in
// `localStorage` rather than on the server. `Layouts.app/1` is rendered by
// every LiveView in `live_session :default`, and none of them should have to
// carry a nav assign or handle a nav event for a rail they do not own.
//
// Everything the rail's state changes is published on `<html>`, which no
// LiveView patch ever touches:
//
//   * `data-nav-rail="pinned" | "collapsed"` — `app.css` turns this into
//     `--nav-rail-page-inset` (the expanded or the collapsed rail width) and
//     into the rail's own width. Hover never writes here: the hover float is
//     a `:hover` width on the fixed rail, so the page does not reflow.
//   * `data-nav-rail-open` — the below-`lg` overlay. Present only while the
//     overlay is open; every mount clears it, which is how navigating to any
//     item closes it.
//
// `theme.js` calls `applyStoredPin` from `<head>`, before first paint, so a
// pinned rail does not render collapsed and then jump on reload; the hook's
// `mounted()` does the same again on every live navigation.
//
// Every storage access is guarded: the `localStorage` getter itself throws
// when site data is blocked, `setItem` throws when the quota is full, and
// either one inside `mounted()` would abort the page's other hooks. An
// absent, unreadable or unrecognised value reads as unpinned.

export const NAV_RAIL_STORAGE_KEY = "arbiter:nav-rail"

const PINNED = "pinned"
const PIN_SELECTOR = '[phx-click="toggle-nav-pin"]'
const TOGGLE_ID = "nav-rail-toggle"

export function navRailStorage(scope) {
  try {
    return (scope || globalThis).localStorage || null
  } catch (_error) {
    return null
  }
}

export function readPinned(store) {
  try {
    return !!store && store.getItem(NAV_RAIL_STORAGE_KEY) === PINNED
  } catch (_error) {
    return false
  }
}

export function writePinned(store, pinned) {
  try {
    if (!store) return
    if (pinned) store.setItem(NAV_RAIL_STORAGE_KEY, PINNED)
    else store.removeItem(NAV_RAIL_STORAGE_KEY)
  } catch (_error) {
    // A full or blocked store costs the operator the preference across
    // reloads, not the pin on this page.
  }
}

export function applyPinned(root, pinned) {
  if (root) root.setAttribute("data-nav-rail", pinned ? PINNED : "collapsed")
}

/** The pre-paint half, run from `theme.js` in `<head>`. Never throws. */
export function applyStoredPin(doc, store) {
  try {
    applyPinned(doc && doc.documentElement, readPinned(store))
  } catch (_error) {
    // No document to write to; the stylesheet's collapsed default stands.
  }
}

export function setOverlayOpen(root, toggle, open) {
  if (root) {
    if (open) root.setAttribute("data-nav-rail-open", "")
    else root.removeAttribute("data-nav-rail-open")
  }

  if (toggle) toggle.setAttribute("aria-expanded", open ? "true" : "false")
}

export const NavRail = {
  mounted() {
    const env = this.env || {
      doc: document,
      win: window,
      store: navRailStorage(window)
    }
    this.env = env

    const { doc, win, store } = env
    const root = doc.documentElement

    this.pinned = readPinned(store)
    this.overlayOpen = false

    applyPinned(root, this.pinned)
    this.setOverlay(false)
    this.syncPressed()

    // `sidebar_nav/1`'s pin button carries `phx-click="toggle-nav-pin"`, and
    // no LiveView handles that event — the pin is this hook's. LiveView binds
    // clicks on `window`, so stopping the event here, on its way up, is what
    // keeps it from ever reaching the server.
    this.onClick = (event) => {
      const target = event.target
      if (!target || typeof target.closest !== "function") return

      if (target.closest(PIN_SELECTOR)) {
        event.stopPropagation()
        event.preventDefault()
        this.setPinned(!this.pinned)
        return
      }

      // A rail link is a live navigation; close the overlay now rather than
      // when the next page's mount gets round to it.
      if (target.closest("a[href]")) this.setOverlay(false)
    }
    this.el.addEventListener("click", this.onClick)

    // The hamburger and the backdrop live outside this element, so they talk
    // to it with `JS.dispatch`, which bubbles to `window`.
    this.windowListeners = {
      "nav-rail:toggle": () => this.setOverlay(!this.overlayOpen),
      "nav-rail:open": () => this.setOverlay(true),
      "nav-rail:close": () => this.setOverlay(false),
      keydown: (event) => {
        if (this.overlayOpen && event && event.key === "Escape") this.setOverlay(false)
      },
      // A pin made in another tab, the same way `theme.js` follows the theme.
      storage: (event) => {
        if (event && event.key === NAV_RAIL_STORAGE_KEY) {
          this.applyPin(event.newValue === PINNED)
        }
      }
    }

    for (const [type, fn] of Object.entries(this.windowListeners)) {
      win.addEventListener(type, fn)
    }
  },

  // The pin button's `aria-pressed` is rendered by the server, which does not
  // know about the pin, so a patch that touches the rail puts the server's
  // value back. Put ours back after it.
  updated() {
    this.syncPressed()
  },

  destroyed() {
    const { win } = this.env

    for (const [type, fn] of Object.entries(this.windowListeners || {})) {
      win.removeEventListener(type, fn)
    }

    this.windowListeners = {}
  },

  setPinned(pinned) {
    writePinned(this.env.store, pinned)
    this.applyPin(pinned)
  },

  applyPin(pinned) {
    const { doc, win } = this.env

    this.pinned = pinned
    applyPinned(doc.documentElement, pinned)
    this.syncPressed()

    // The page just got wider or narrower without the window changing size.
    // The session dock re-decides whether a side panel fits (and its
    // terminal refits) on `resize`, so tell it.
    try {
      win.dispatchEvent(new Event("resize"))
    } catch (_error) {
      // No `Event` constructor to hand; the dock catches up on its next resize.
    }
  },

  setOverlay(open) {
    const { doc } = this.env

    this.overlayOpen = open
    setOverlayOpen(doc.documentElement, doc.getElementById(TOGGLE_ID), open)
  },

  syncPressed() {
    const pin = this.el.querySelector(PIN_SELECTOR)
    if (pin) pin.setAttribute("aria-pressed", this.pinned ? "true" : "false")
  }
}
