// The session dock's client half (bd-dlc136): which sessions are open, in what
// order, and which one is expanded.
//
// That is a *browser* preference, not fleet state — the dashboard is
// loopback-only and single-operator (§10.4), so there is no user record to
// hang it on and no cross-device case to serve — so it lives in
// `localStorage` and the server is told about it on mount.
//
// `localStorage` is the one API on this page that can throw on **read**: the
// `window.localStorage` getter itself raises `SecurityError` when site data
// is blocked (Safari private mode, a "block third-party cookies" setting on
// some embeddings), and `setItem` raises when the quota is full. An
// exception inside `mounted()` aborts the hook and takes the rest of the
// page's hook lifecycle with it, so every access here is guarded and every
// failure reads as "nothing is open".
//
// `readDockState`/`writeDockState` take the store as an argument rather than
// reaching for `window` so `test/js/session_dock_test.mjs` can hand them
// stores that fail in each of those ways.

export const DOCK_STORAGE_KEY = "arbiter:session-dock"

const EMPTY = Object.freeze({ open: [], expanded: null })

// `window.localStorage` can throw on access, so even getting hold of the
// store is a guarded operation.
export function dockStorage(scope) {
  try {
    return (scope || globalThis).localStorage || null
  } catch (_error) {
    return null
  }
}

export function readDockState(store) {
  let raw = null

  try {
    if (!store) return { ...EMPTY }
    raw = store.getItem(DOCK_STORAGE_KEY)
  } catch (_error) {
    return { ...EMPTY }
  }

  if (!raw) return { ...EMPTY }

  try {
    return normalize(JSON.parse(raw))
  } catch (_error) {
    return { ...EMPTY }
  }
}

export function writeDockState(store, state) {
  try {
    if (!store) return
    store.setItem(DOCK_STORAGE_KEY, JSON.stringify(normalize(state)))
  } catch (_error) {
    // A full or read-only store costs the operator the preference, not the
    // page. There is nowhere useful to report this to.
  }
}

// The one shape the rest of the code is allowed to see. Anything else —
// a previous version's payload, a hand-edited value, a half-written write —
// degrades to as much of it as is well-formed.
function normalize(state) {
  if (!state || typeof state !== "object" || Array.isArray(state)) return { ...EMPTY }

  const open = Array.isArray(state.open)
    ? state.open.filter((id) => typeof id === "string" && id.length > 0)
    : []

  const expanded =
    typeof state.expanded === "string" && open.includes(state.expanded) ? state.expanded : null

  return { open, expanded }
}

// The hook itself. It owns no DOM — the dock's markup is entirely
// server-rendered — so it needs no `phx-update="ignore"`; it is only the
// bridge between `localStorage` and the LiveView.
export const SessionDock = {
  mounted() {
    this.store = dockStorage(window)

    this.handleEvent("session-dock:persist", (state) => writeDockState(this.store, state))

    // Told, not asked: the server re-validates this against the sessions that
    // actually exist and pushes back whatever survived, which is also how a
    // stale id gets swept out of storage.
    this.pushEvent("restore", readDockState(this.store))
  }
}
