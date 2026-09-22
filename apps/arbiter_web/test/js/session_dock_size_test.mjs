// The expanded window's size presets (bd-covojz), under `node --test`.
//
// Three presets, not free drag-resize: the epic rejected drag-resize partly
// because a continuous resize is the worst case for terminal refit, and each
// of these is a single discrete geometry change phase 2's refit path already
// handles.
//
// Two of the three are pure CSS once the server has rendered the right classes.
// The one decision that is not — whether a **Side panel** actually fits, and
// what to do when it does not — is arithmetic over the viewport, and it lives
// here so it can be checked without a browser: §6.3's floor is 80 columns,
// below which Claude Code's TUI wraps and degrades, and a side panel that
// squeezed the page under ~`MIN_PAGE_WIDTH` would have taken away the very
// thing it exists for (reading a page while talking to a session).
//
//   node --test apps/arbiter_web/test/js/session_dock_size_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import {
  DOCK_SIZES,
  MIN_COLS,
  MIN_PAGE_WIDTH,
  SIDE_FRACTION,
  minColumnsWidth,
  normalizeDockSize,
  resolveDockSize,
  sidePanelWidth
} from "../../assets/js/session_dock_size.mjs"

test("the three presets are the only names", () => {
  assert.deepEqual(DOCK_SIZES, ["compact", "side", "max"])
})

test("anything that is not a preset name reads as Compact", () => {
  for (const size of ["compact", "side", "max"]) {
    assert.equal(normalizeDockSize(size), size)
  }

  for (const junk of [null, undefined, "", "COMPACT", "side-panel", 7, {}, [], "maximized"]) {
    assert.equal(normalizeDockSize(junk), "compact", `for ${JSON.stringify(junk)}`)
  }
})

// §6.3: a terminal cannot reflow meaningfully below ~80 columns. The panel's
// floor is therefore measured in *columns at the current font*, not in pixels,
// plus the chrome between the panel's edge and the first cell.
test("the column floor is 80 columns at the measured cell, plus chrome", () => {
  assert.equal(MIN_COLS, 80)
  assert.equal(minColumnsWidth(7.8, 30), Math.ceil(80 * 7.8) + 30)
  // A cell that has not been measured yet must not collapse the floor to the
  // chrome alone — that would render a 30px "terminal".
  assert.equal(minColumnsWidth(0, 30), null)
  assert.equal(minColumnsWidth(NaN, 30), null)
  assert.equal(minColumnsWidth(-3, 30), null)
})

test("the side panel is a share of the viewport but never under the column floor", () => {
  assert.equal(SIDE_FRACTION, 0.35)

  // Wide: the share wins.
  assert.equal(sidePanelWidth(2400, 640), Math.round(2400 * 0.35))
  // Narrow: the floor wins, so 80 columns still fit.
  assert.equal(sidePanelWidth(1400, 640), 640)
})

test("Compact and Maximized are never second-guessed", () => {
  for (const size of ["compact", "max"]) {
    assert.deepEqual(resolveDockSize(size, { viewportWidth: 320, minColumnsWidth: 640 }), {
      size,
      fallback: false
    })
  }
})

test("a side panel that leaves a usable page is taken as asked", () => {
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1920, minColumnsWidth: 640 }), {
    size: "side",
    fallback: false
  })
})

// The narrow-viewport rule, stated as arithmetic: a panel wide enough for 80
// columns plus a page still worth looking at, or nothing.
test("a viewport too narrow for both the panel and a usable page falls back to Maximized", () => {
  assert.equal(MIN_PAGE_WIDTH, 480)

  // 640 of panel out of 1000 leaves 360 — under the floor for a page.
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1000, minColumnsWidth: 640 }), {
    size: "max",
    fallback: true
  })

  // Exactly on the boundary still counts as fitting.
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1120, minColumnsWidth: 640 }), {
    size: "side",
    fallback: false
  })
})

test("an unmeasured cell falls back to the CSS default floor rather than to nothing", () => {
  // `null` is what `minColumnsWidth` answers before the webfont has landed and
  // xterm has measured a cell. The panel still has to decide, and it decides
  // with the same 640px the stylesheet defaults to.
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1920, minColumnsWidth: null }), {
    size: "side",
    fallback: false
  })

  assert.deepEqual(resolveDockSize("side", { viewportWidth: 900, minColumnsWidth: null }), {
    size: "max",
    fallback: true
  })
})

test("a viewport that has not been measured yet never claims a fallback", () => {
  for (const width of [0, null, undefined, NaN, -100]) {
    assert.deepEqual(
      resolveDockSize("side", { viewportWidth: width, minColumnsWidth: 640 }),
      { size: "side", fallback: false },
      `for ${width}`
    )
  }
})

// bd-2qqqbp: the page's 480px is 480px of what is *left*, and a left rail takes
// from the same width the panel and the page share. Without the rail in this
// subtraction the floor quietly stops meaning what it says: the dock would keep
// a side panel over a page it has already squeezed under `MIN_PAGE_WIDTH`.
test("a left rail comes out of the page's share before a side panel is judged to fit", () => {
  // 1180 − 56 of rail − 640 of panel = 484: still a usable page.
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1180, railWidth: 56 }), {
    size: "side",
    fallback: false
  })

  // Ten pixels narrower and the page is under the floor — which the one-sided
  // arithmetic would have called a fit (1170 − 640 = 530).
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1170, railWidth: 56 }), {
    size: "max",
    fallback: true
  })
})

test("no rail is exactly the answer from before the rail existed", () => {
  // The contract lands at `--nav-rail-page-inset: 0px` and nothing sets it yet,
  // so every reading of "no rail" — absent, unreadable, zero — has to leave
  // today's answers untouched.
  assert.deepEqual(resolveDockSize("side", { viewportWidth: 1170 }), {
    size: "side",
    fallback: false
  })

  for (const railWidth of [undefined, null, NaN, 0, "56px", -100]) {
    assert.deepEqual(
      resolveDockSize("side", { viewportWidth: 1170, railWidth }),
      { size: "side", fallback: false },
      `for ${railWidth}`
    )
  }
})

// -- the controller the hook is made of ---------------------------------------
//
// The dock's hook owns two pieces of global state on behalf of the expanded
// window: `data-dock-size` on `<html>` (which is what insets the page for a
// side panel) and `--session-dock-min-cols` (the 80-column floor, refined from
// the real font once it has been measured). Both are writes to the document,
// so they live behind a controller that takes the document as an argument and
// can be checked against a fake one.

import {
  applyColumnFloor,
  createDockSizeController
} from "../../assets/js/session_dock_size.mjs"

function fakeDoc({ railInset = null } = {}) {
  const props = new Map()

  const doc = {
    props,
    documentElement: {
      dataset: {},
      style: {
        setProperty: (name, value) => props.set(name, value),
        removeProperty: (name) => props.delete(name)
      }
    }
  }

  // A document that can report computed custom properties — which is how the
  // controller learns how much of the left edge the rail is holding. Omitted,
  // it stands in for the documents that cannot (a hook that ran before layout,
  // or a non-browser).
  if (railInset !== null) {
    doc.defaultView = {
      getComputedStyle: () => ({
        getPropertyValue: (name) => (name === "--nav-rail-page-inset" ? railInset : "")
      })
    }
  }

  return doc
}

function controller(doc, { viewportWidth = 1920, columnWidth = 7.8 } = {}) {
  const reported = []

  const subject = createDockSizeController({
    doc,
    viewportWidth: () => viewportWidth,
    columnWidth: () => columnWidth,
    onFallback: (fallback) => reported.push(fallback)
  })

  return { subject, reported }
}

test("the measured column floor reaches the stylesheet", () => {
  const doc = fakeDoc()

  applyColumnFloor(doc, 7.8)
  assert.equal(doc.props.get("--session-dock-min-cols"), `${Math.ceil(80 * 7.8) + 30}px`)

  // An unmeasured cell leaves the stylesheet's own default in place rather
  // than writing a nonsense floor over it.
  applyColumnFloor(doc, 0)
  assert.equal(doc.props.has("--session-dock-min-cols"), false)
})

test("only a side panel that fits insets the page", () => {
  const doc = fakeDoc()
  const { subject } = controller(doc)

  subject.set("compact")
  assert.equal(doc.documentElement.dataset.dockSize, "compact")

  subject.set("side")
  assert.equal(doc.documentElement.dataset.dockSize, "side")

  subject.set("max")
  assert.equal(doc.documentElement.dataset.dockSize, "max")
})

test("a viewport too narrow for a side panel is reported once, not every frame", () => {
  const doc = fakeDoc()
  const { subject, reported } = controller(doc, { viewportWidth: 1000 })

  subject.set("side")

  assert.equal(doc.documentElement.dataset.dockSize, "max")
  assert.deepEqual(reported, [true])

  // The same answer again is not news — the server is not told twice.
  subject.refresh()
  subject.refresh()
  assert.deepEqual(reported, [true])
})

// The other half of that guard, and the one the first round got wrong: a
// `set` is not a frame of a drag, it is the answer to a question the server
// has just asked. The server clears `size_fallback?` on every `set_size`,
// `expand_window/2` and `collapse_window/1` and then re-asks over
// `session-dock:size` — so if a re-asked size that did not change were
// swallowed here, the server would sit at `false` forever and render a side
// panel on a viewport that cannot fit it, un-inset and unlabelled.
test("a re-asked size reports the fallback again even though it did not change", () => {
  const doc = fakeDoc()
  const { subject, reported } = controller(doc, { viewportWidth: 1000 })

  subject.set("side")
  assert.deepEqual(reported, [true])

  // Clicking the already-pressed Side button, or expanding another window
  // whose stored size is also Side: same size, same answer, still said.
  subject.set("side")
  assert.deepEqual(reported, [true, true])

  subject.set("side")
  assert.equal(doc.documentElement.dataset.dockSize, "max")
  assert.deepEqual(reported, [true, true, true])

  // A resize in between is still only reported when it changes something.
  subject.refresh()
  assert.deepEqual(reported, [true, true, true])
})

// The same path on a viewport that *does* fit: re-asking has to re-confirm
// `false` too, since a rejoin re-mounts the server at `false` while this hook
// instance survives holding `true`.
test("a re-asked size that fits re-confirms that there is no fallback", () => {
  const doc = fakeDoc()
  const { subject, reported } = controller(doc, { viewportWidth: 1920 })

  subject.set("side")
  subject.set("side")

  assert.equal(doc.documentElement.dataset.dockSize, "side")
  assert.deepEqual(reported, [false, false])
})

test("a window that grows back into a side panel takes the fallback back", () => {
  const doc = fakeDoc()
  let width = 1000
  const reported = []

  const subject = createDockSizeController({
    doc,
    viewportWidth: () => width,
    columnWidth: () => 7.8,
    onFallback: (fallback) => reported.push(fallback)
  })

  subject.set("side")
  assert.deepEqual(reported, [true])

  width = 1920
  subject.refresh()

  assert.equal(doc.documentElement.dataset.dockSize, "side")
  assert.deepEqual(reported, [true, false])
})

test("leaving Side panel clears a fallback the operator can no longer see", () => {
  const doc = fakeDoc()
  const { subject, reported } = controller(doc, { viewportWidth: 1000 })

  subject.set("side")
  subject.set("compact")

  assert.equal(doc.documentElement.dataset.dockSize, "compact")
  assert.deepEqual(reported, [true, false])
})

// The rail's half of the same contract: the controller is what actually asks,
// and it has to ask the document rather than assume the left edge is free.
test("the controller takes the rail's inset off the width it decides with", () => {
  const doc = fakeDoc({ railInset: "56px" })
  const { subject, reported } = controller(doc, { viewportWidth: 1170, columnWidth: 0 })

  subject.set("side")

  assert.equal(doc.documentElement.dataset.dockSize, "max")
  assert.deepEqual(reported, [true])
})

test("a document that cannot report the rail decides as though there were none", () => {
  const doc = fakeDoc()
  const { subject, reported } = controller(doc, { viewportWidth: 1170, columnWidth: 0 })

  subject.set("side")

  assert.equal(doc.documentElement.dataset.dockSize, "side")
  assert.deepEqual(reported, [false])
})

test("a controller with no document decides without throwing", () => {
  const reported = []

  const subject = createDockSizeController({
    doc: null,
    viewportWidth: () => 1000,
    columnWidth: () => 7.8,
    onFallback: (fallback) => reported.push(fallback)
  })

  assert.doesNotThrow(() => subject.set("side"))
  assert.equal(subject.size, "max")
  assert.deepEqual(reported, [true])
})
