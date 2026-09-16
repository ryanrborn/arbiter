// The terminal's fit arithmetic, under `node --test` (bd-3r2otb, acceptance
// criterion 2).
//
// This is the whole of what `@xterm/addon-fit` used to do for us, and it
// exists because the addon got it wrong in this page's layout: it sizes the
// pane from `getComputedStyle(parent).height`, which Chrome resolves to the
// **border box** when `box-sizing: border-box` is in force — and Tailwind's
// preflight puts it in force everywhere. The pane's own `p-2` was therefore
// counted as usable terminal space, the fit asked for one row more than the
// box could show, and the bottom row of the agent's UI was clipped in half.
//
//   node --test apps/arbiter_web/test/js/session_fit_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { fitGeometry, settleFit } from "../../assets/js/session_fit.mjs"

// The real numbers off the live page: a 640px pane with 16px of padding and a
// 20px cell. 640/20 is a clean 32 rows, which is exactly the trap — the fit
// looks perfect and overflows the content box by the padding.
const PANE = { width: 1200, height: 624, cellWidth: 8, cellHeight: 20 }

test("fits whole rows inside the content box", () => {
  const { cols, rows } = fitGeometry(PANE)

  assert.equal(rows, 31)
  assert.equal(cols, 150)
})

test("never proposes a geometry taller than the box it was given", () => {
  for (let height = 40; height <= 900; height++) {
    const { rows } = fitGeometry({ ...PANE, height })
    assert.ok(
      rows * PANE.cellHeight <= height,
      `${rows} rows of ${PANE.cellHeight}px do not fit in ${height}px`
    )
  }
})

test("never proposes a geometry wider than the box it was given", () => {
  for (let width = 100; width <= 2000; width += 7) {
    const { cols } = fitGeometry({ ...PANE, width, scrollbarWidth: 15 })
    assert.ok(
      cols * PANE.cellWidth <= width - 15,
      `${cols} columns of ${PANE.cellWidth}px do not fit in ${width - 15}px`
    )
  }
})

test("leaves room for the viewport's scrollbar", () => {
  const without = fitGeometry(PANE).cols
  const with_ = fitGeometry({ ...PANE, scrollbarWidth: 16 }).cols

  assert.equal(with_, without - 2)
})

test("fractional cells still land inside the box", () => {
  // A fractional device pixel ratio gives xterm a fractional css cell, and
  // rounding up anywhere here is a clipped row.
  const { rows } = fitGeometry({ ...PANE, height: 500, cellHeight: 16.25 })

  assert.equal(rows, 30)
  assert.ok(30 * 16.25 <= 500)
})

test("refuses to size a pane that has not been laid out", () => {
  // A background tab, or a mount before first paint. The old addon clamped to
  // 1 row here, and that geometry is *pushed to the server*, where it resizes
  // the pane every other attached client shares.
  assert.equal(fitGeometry({ ...PANE, height: 0 }), null)
  assert.equal(fitGeometry({ ...PANE, width: 0 }), null)
  assert.equal(fitGeometry({ ...PANE, cellHeight: 0 }), null)
  assert.equal(fitGeometry({ ...PANE, cellWidth: 0 }), null)
  assert.equal(fitGeometry({ ...PANE, height: NaN }), null)
})

test("keeps a floor so a sliver of a container is still a terminal", () => {
  const { cols, rows } = fitGeometry({ ...PANE, width: 4, height: 4 })

  assert.equal(cols, 2)
  assert.equal(rows, 1)
})

// -- settleFit (bd-14b11h) ----------------------------------------------------
//
// A LiveView navigation back to /sessions/<id> re-mounts the hook, and the
// hook's mount-time fit ran *synchronously*: one measurement, and if the pane
// had no box yet it gave up and left xterm on its 80x24 default. That default
// then went out as the join's `cols`/`rows`, resized the pane every client
// shares, and the snapshot the server captured in the same breath was reflowed
// for a size the agent had not redrawn at — the garbled terminal in #1733.
//
// `settleFit` is that retry loop, with the frame scheduler injected so it can
// be driven here rather than in a browser.

test("settleFit reports a pane that is already laid out without waiting a frame", () => {
  const frames = []
  const settled = []

  settleFit({
    measure: () => ({ cols: 80, rows: 24 }),
    schedule: (cb) => frames.push(cb),
    onSettled: (geometry) => settled.push(geometry)
  })

  assert.deepEqual(settled, [{ cols: 80, rows: 24 }])
  assert.equal(frames.length, 0, "a measurable pane must not cost a frame")
})

test("settleFit keeps measuring until the container has a box", () => {
  const frames = []
  const settled = []
  let attempts = 0

  settleFit({
    // Two frames of 0x0 — a mount whose layout has not settled — then a box.
    measure: () => (++attempts < 3 ? null : { cols: 96, rows: 30 }),
    schedule: (cb) => frames.push(cb),
    onSettled: (geometry) => settled.push(geometry)
  })

  assert.deepEqual(settled, [], "nothing is reported while the pane is unmeasurable")

  frames.shift()()
  assert.deepEqual(settled, [])

  frames.shift()()
  assert.deepEqual(settled, [{ cols: 96, rows: 30 }])
  assert.equal(attempts, 3)
})

test("settleFit gives up after its frame budget and says so exactly once", () => {
  const frames = []
  const settled = []

  settleFit({
    measure: () => null,
    schedule: (cb) => frames.push(cb),
    frames: 3,
    onSettled: (geometry) => settled.push(geometry)
  })

  // A background tab never lays out. The caller still has to connect, so the
  // budget ends in a `null` rather than in silence.
  for (let i = 0; i < 10 && frames.length > 0; i++) frames.shift()()

  assert.deepEqual(settled, [null])
})

test("settleFit stops when the hook that started it is disposed", () => {
  const frames = []
  const settled = []

  const cancel = settleFit({
    measure: () => null,
    schedule: (cb) => frames.push(cb),
    frames: 5,
    onSettled: (geometry) => settled.push(geometry)
  })

  cancel()
  while (frames.length > 0) frames.shift()()

  assert.deepEqual(settled, [], "a navigated-away hook must not connect or resize")
})
