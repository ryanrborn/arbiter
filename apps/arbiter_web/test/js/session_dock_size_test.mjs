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

function fakeDoc() {
  const props = new Map()

  return {
    props,
    documentElement: {
      dataset: {},
      style: {
        setProperty: (name, value) => props.set(name, value),
        removeProperty: (name) => props.delete(name)
      }
    }
  }
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
