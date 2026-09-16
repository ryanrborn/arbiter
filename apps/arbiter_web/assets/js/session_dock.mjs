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

// Regions inside the dock whose scroll offset has to survive a live
// navigation. See `rememberScroll`/`restoreScroll` for why that is not free.
export const DOCK_SCROLL_ATTR = "data-dock-scroll"

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

// -- the handover from another view -------------------------------------------
//
// `ArbiterWeb.SessionIndexLive` hands a session to the dock with a
// `push_event` — on Launch, and from any row's Open — which LiveView delivers
// as a `window` event, so a *sibling* sticky view hears it even though it
// shares no assigns with the page that sent it. (Before bd-a292yj deleted it,
// `/sessions/:id` did the same thing on mount.)
//
// When the dock's hook is already mounted it catches the event directly. On a
// **cold load** it may not be: the parent view joins, applies its patch and
// dispatches its events before its sticky children have joined at all, and the
// request would land on nothing. So it is also remembered here, by a listener
// installed when this module is imported — which `app.js` does before
// `liveSocket.connect()` — and claimed by whichever of the two gets there
// first.
let pendingOpen = null

export function rememberOpenRequest(detail) {
  pendingOpen = detail && typeof detail.id === "string" && detail.id !== "" ? detail.id : null
}

/** The pending session id, if any. Claiming it consumes it. */
export function takeOpenRequest() {
  const id = pendingOpen
  pendingOpen = null
  return id
}

if (typeof window !== "undefined") {
  window.addEventListener("phx:session-dock:open", (event) => rememberOpenRequest(event.detail))
}

// -- the resume book ----------------------------------------------------------
//
// Phase 2 (bd-9myzv8): collapsing a window disposes the xterm *and* the
// `SessionStream` that held `last_seq`, because the acceptance criterion is
// that a strip of collapsed windows holds zero xterm instances and zero live
// sockets. The byte offset the next expand has to resume from therefore cannot
// live in either of them, so it lives here.
//
// Deliberately **in memory**, never in `localStorage`. A resumed join replays
// a delta, and a delta is only meaningful painted onto the screen it was
// computed against. After a reload there is no such screen, so the right thing
// there is a snapshot — which is exactly what an empty book produces.
const resumePoints = new Map()

export function rememberResume(sessionId, seq) {
  if (!sessionId) return
  if (!Number.isInteger(seq) || seq < 0) return

  // Monotonic. A dispose that lands after something else has already advanced
  // the offset must not rewind it into replaying bytes twice.
  const known = resumePoints.get(sessionId)
  if (known !== undefined && known >= seq) return

  resumePoints.set(sessionId, seq)
}

export function resumeFrom(sessionId) {
  const seq = resumePoints.get(sessionId)
  return seq === undefined ? null : seq
}

export function forgetResume(sessionId) {
  resumePoints.delete(sessionId)
}

// -- the last screen of a session that ended (bd-a292yj) ----------------------
//
// A window whose session ended keeps its pane, read-only, until the operator
// dismisses it. That survives collapsing (the server keeps rendering the
// element) but it cannot survive a **LiveView rejoin**: a rejoin re-renders
// the dock from an empty `mount/3`, which removes every window element and
// disposes every xterm before `restore` puts them back. A live pane recovers
// by replaying its stream from `lastSeq`; a dead one has no stream left.
//
// So the text is kept here, alongside the resume book and for the same reason:
// in memory, never in `localStorage` — after a full reload there is no window
// to restore it into, and the honest answer there is "this ended before this
// browser session", which is exactly what an empty book produces.
const finalScreens = new Map()

export function rememberFinalScreen(sessionId, text) {
  if (!sessionId || typeof text !== "string") return
  finalScreens.set(sessionId, text)
}

export function finalScreenFor(sessionId) {
  const text = finalScreens.get(sessionId)
  return text === undefined ? null : text
}

export function forgetFinalScreen(sessionId) {
  finalScreens.delete(sessionId)
}

// Which windows are frozen is server state a rejoin resets, the same way
// `open`/`expanded` are — and it needs the same answer: the client says so in
// `restore`. It cannot be read off the DOM at that moment, which was the
// tempting spelling: `reconnected()` runs *after* the join reply has been
// patched in, and that patch — rendered from a fresh `mount/3` with nothing
// open — has already removed every pane there was to read.
const frozenSessions = new Set()

export function markFrozen(sessionId) {
  if (typeof sessionId === "string" && sessionId !== "") frozenSessions.add(sessionId)
}

export function forgetFrozen(sessionId) {
  frozenSessions.delete(sessionId)
}

/** The sessions this browser knows have ended under an open window. */
export function frozenIds() {
  return Array.from(frozenSessions)
}

// -- scroll survival ----------------------------------------------------------
//
// `sticky: true` keeps the dock's process and its DOM node across a
// `live_redirect`, but the client gets there by *re-parenting* the node:
// `LiveSocket.replaceMain` does `stickies.forEach(el =>
// newMainEl.appendChild(el))` before swapping the main container in. Detaching
// an element, even for the one frame that takes, resets `scrollTop` on every
// scrollable node inside it — so the dock coming through navigation intact and
// the dock's *scroll position* coming through it are two different claims, and
// only the first one is free.
//
// So the dock keeps its own book of offsets, written on every scroll inside a
// marked region and read back when LiveView says it has navigated. Phase 2's
// terminal frame carries the same attribute and gets the same treatment.

export function rememberScroll(tops, target) {
  if (!tops || !target || typeof target.hasAttribute !== "function") return tops
  if (!target.id || typeof target.scrollTop !== "number") return tops
  if (!target.hasAttribute(DOCK_SCROLL_ATTR)) return tops

  tops.set(target.id, target.scrollTop)
  return tops
}

export function restoreScroll(root, tops) {
  if (!root || !tops || typeof root.querySelector !== "function") return

  for (const [id, top] of tops) {
    // An attribute selector rather than `#id`: ids here embed session UUIDs,
    // and `CSS.escape` is not something this module should have to assume.
    const el = root.querySelector(`[id="${id}"]`)
    if (el) el.scrollTop = top
  }
}

// The hook itself. It owns no DOM — the dock's markup is entirely
// server-rendered — so it needs no `phx-update="ignore"`; it is only the
// bridge between `localStorage` and the LiveView.
export const SessionDock = {
  mounted() {
    this.store = dockStorage(window)
    this.scrollTops = new Map()
    this.restoring = false

    // Capture phase: `scroll` does not bubble, but a capture listener on an
    // ancestor still sees it on the way down to the target. The guard is what
    // stops the book being overwritten by the zeroes our own restore causes.
    this.onScroll = (event) => {
      if (!this.restoring) rememberScroll(this.scrollTops, event.target)
    }
    this.el.addEventListener("scroll", this.onScroll, true)

    // `phx:navigate` is dispatched from inside `replaceMain`'s DOM update, one
    // statement *before* the incoming view's join patch runs — and it is that
    // patch, re-inserting the preserved dock node, that zeroes the offsets. So
    // restoring here directly is always too early: it lands, the patch wipes
    // it, and the resulting `scroll` events write the zeroes back into the
    // book. Wait a frame for the patch, restore, then wait one more for the
    // `scroll` events our own write produces before listening again.
    this.onNavigate = () => {
      this.restoring = true

      requestAnimationFrame(() => {
        restoreScroll(this.el, this.scrollTops)
        requestAnimationFrame(() => {
          this.restoring = false
        })
      })
    }
    window.addEventListener("phx:navigate", this.onNavigate)

    this.handleEvent("session-dock:persist", (state) => writeDockState(this.store, state))

    // Dismiss is "forget this window", and an ended window's last screen — and
    // the note that it ended at all — are part of what is being forgotten.
    this.handleEvent("session-dock:forget", ({ id }) => {
      forgetFinalScreen(id)
      forgetFrozen(id)
    })

    // The handover from `/sessions/:id`. Claimed here too so that a later
    // remount — a LiveView rejoin re-runs every `mounted()` — cannot re-open a
    // window the operator has since dismissed.
    this.handleEvent("session-dock:open", ({ id }) => {
      takeOpenRequest()
      if (typeof id === "string" && id !== "") this.pushEvent("open", { id })
    })

    // Told, not asked: the server re-validates this against the sessions that
    // actually exist and pushes back whatever survived, which is also how a
    // stale id gets swept out of storage.
    this.pushEvent("restore", this.dockState())

    // ...and then, in that order, whatever arrived before this hook existed:
    // `restore` decides which windows are open, `open` adds one to them.
    const pending = takeOpenRequest()
    if (pending) this.pushEvent("open", { id: pending })
  },

  // A LiveView rejoin — a server restart, a laptop waking up — re-runs the
  // dock's `mount/3`, so `open_ids` is back to `[]` and the strip re-renders
  // empty. It does **not** re-mount hooks, so without this nothing ever tells
  // the server what was open again and the dock stays empty until the next
  // full page load, taking the expanded window's terminal with it.
  //
  // That is the one moment §10.1 is about: the sessions outlive the restart on
  // purpose, and the operator is meant to see "reconnecting…" and get their
  // terminal back — not an empty strip.
  reconnected() {
    this.pushEvent("restore", this.dockState())
  },

  // Storage owns which windows are open; the DOM owns which of them are
  // holding a dead pane. Both have to reach a re-mounted server view, or a
  // rejoin quietly turns an ended window into "its output is unavailable"
  // while its pane is still on screen.
  dockState() {
    return { ...readDockState(this.store), frozen: frozenIds() }
  },

  destroyed() {
    window.removeEventListener("phx:navigate", this.onNavigate)
  }
}
