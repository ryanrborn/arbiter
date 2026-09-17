// The expanded window's size presets (bd-covojz): **Compact**, **Side panel**
// and **Maximized**.
//
// Three presets rather than a drag handle, and deliberately: the epic
// (bd-1hdg5b) rejected free-floating windows partly because a continuous
// drag-resize is the worst case for terminal refit — a hundred geometry
// changes a second against a pane every attached client shares. Each of these
// is one discrete change, which is exactly what phase 2's refit path already
// handles (fit after the layout settles, send cols/rows to the pane, force a
// redraw when the geometry moved).
//
// Two of the three are pure CSS once the server has rendered the right classes
// on the window. The one decision that is not is **whether a side panel fits
// at all**, and that is arithmetic over the viewport rather than a media
// query, because the answer has to reach the title bar (the operator is told
// when their side panel became a maximized one) and because the floor it is
// measured against is a *font* measurement, not a pixel constant:
//
//   * §6.3: below ~80 columns Claude Code's TUI wraps and degrades, so the
//     panel is never narrower than 80 columns at the pane's current cell;
//   * a panel that squeezed the page under `MIN_PAGE_WIDTH` would have taken
//     away the one thing a side panel exists for — reading another page while
//     talking to a session — so at that point it says so and maximizes.
//
// Everything here is pure and DOM-free so `test/js/session_dock_size_test.mjs`
// can check the arithmetic without a browser; `measureColumnWidth` below is
// the one function that touches the document, and it is a measurement, not a
// decision.

/** The preset names, in the order the title-bar control offers them. */
export const DOCK_SIZES = ["compact", "side", "max"]

/** §6.3's floor: a terminal cannot reflow meaningfully below this. */
export const MIN_COLS = 80

/** How much page has to be left to the panel's left for it to be worth it. */
export const MIN_PAGE_WIDTH = 480

/** The share of the viewport a side panel takes when the floor is not binding. */
export const SIDE_FRACTION = 0.35

// What the stylesheet's `--session-dock-min-cols` defaults to, and so what the
// arithmetic has to assume before a cell has been measured. Keep the two in
// step: `app.css`'s `:root` declares the same number.
export const DEFAULT_MIN_COLUMNS_WIDTH = 640

// The distance between the panel's outer edge and the first cell of the pane:
// the frame's two borders plus the pane's own padding, with a little left over
// for xterm's viewport scrollbar. Under-counting it is what clips column 80.
export const PANE_CHROME_PX = 30

// The terminal's own font size (`session_terminal.mjs` sets `fontSize: 13`).
// A cell measured at any other size would answer a different question.
export const TERMINAL_FONT_SIZE = 13

/** Anything that is not one of the three presets is Compact. */
export function normalizeDockSize(size) {
  return DOCK_SIZES.includes(size) ? size : "compact"
}

/**
 * 80 columns at `cellWidth`, plus the chrome around them — or `null` when the
 * cell has not been measured yet, which is a different answer from "zero" and
 * must not be allowed to collapse the floor to the chrome alone.
 */
export function minColumnsWidth(cellWidth, chrome = PANE_CHROME_PX) {
  if (!Number.isFinite(cellWidth) || cellWidth <= 0) return null
  return Math.ceil(MIN_COLS * cellWidth) + chrome
}

/** A share of the viewport, floored at 80 columns. */
export function sidePanelWidth(viewportWidth, floor) {
  return Math.max(Math.round(viewportWidth * SIDE_FRACTION), floor)
}

/**
 * The size that will actually be rendered, and whether that is a fallback the
 * operator has to be told about.
 *
 * Only `"side"` can be refused: Compact and Maximized fit any viewport that
 * can show the dock at all.
 */
export function resolveDockSize(requested, metrics = {}) {
  const size = normalizeDockSize(requested)
  if (size !== "side") return { size, fallback: false }

  const viewportWidth = metrics.viewportWidth
  // Nothing measured yet — a hook that ran before layout, or a non-browser.
  // Refusing on no evidence would flash a maximized window on every load.
  if (!Number.isFinite(viewportWidth) || viewportWidth <= 0) {
    return { size: "side", fallback: false }
  }

  const floor = Number.isFinite(metrics.minColumnsWidth)
    ? metrics.minColumnsWidth
    : DEFAULT_MIN_COLUMNS_WIDTH

  const fits = viewportWidth - sidePanelWidth(viewportWidth, floor) >= MIN_PAGE_WIDTH

  return fits ? { size: "side", fallback: false } : { size: "max", fallback: true }
}

// -- the one measurement ------------------------------------------------------

/**
 * The width of one monospace cell at the terminal's font, in CSS pixels.
 *
 * Measured off a canvas rather than off the pane, because the panel's width
 * has to be decided *before* there is a pane in it to measure — and on the
 * same face and size xterm uses, or the 80 columns this buys would be 80 of
 * some other font's columns. Returns `null` when there is no canvas to measure
 * with, which the caller reads as "use the stylesheet's default".
 */
export function measureColumnWidth(doc = globalThis.document) {
  try {
    if (!doc || typeof doc.createElement !== "function") return null

    const context = doc.createElement("canvas").getContext("2d")
    if (!context) return null

    const family = readMonoFamily(doc)
    context.font = `${TERMINAL_FONT_SIZE}px ${family}`

    // Ten cells, then divided: one glyph's advance rounds badly at this size,
    // and the error is multiplied by 80 downstream.
    const width = context.measureText("0000000000").width / 10

    return Number.isFinite(width) && width > 0 ? width : null
  } catch (_error) {
    return null
  }
}

function readMonoFamily(doc) {
  const fallback = "ui-monospace, SFMono-Regular, Menlo, monospace"

  try {
    const view = doc.defaultView
    if (!view || typeof view.getComputedStyle !== "function") return fallback

    const value = view.getComputedStyle(doc.documentElement).getPropertyValue("--font-mono")
    return value && value.trim() !== "" ? value.trim() : fallback
  } catch (_error) {
    return fallback
  }
}

// -- the document's half ------------------------------------------------------
//
// Two writes, both on `<html>` so they outlive every page the sticky dock
// navigates through:
//
//   * `--session-dock-min-cols` — the 80-column floor in pixels, once the
//     terminal's real font has been measured. The stylesheet ships a default
//     so the panel has a sane width before (and without) this.
//   * `data-dock-size` — the size the expanded window is *actually* rendering
//     at, which `app.css` turns into the page's right inset. Only a side panel
//     that fits takes any room, which is why this is the resolved size rather
//     than the requested one.

/** Publish the measured 80-column floor. A cell we could not measure is left alone. */
export function applyColumnFloor(doc, cellWidth) {
  const floor = minColumnsWidth(cellWidth)
  const root = documentRoot(doc)
  if (!root) return floor

  if (floor === null) root.style.removeProperty("--session-dock-min-cols")
  else root.style.setProperty("--session-dock-min-cols", `${floor}px`)

  return floor
}

/**
 * The expanded window's size, as the document sees it.
 *
 * `set` is the server's word (a preset was picked, a window was expanded or
 * collapsed); `refresh` is the browser's (the viewport moved, the font
 * landed). Both go through the same decision, and `onFallback` fires only when
 * the answer *changes* — a resize drag must not put a message on the wire per
 * frame.
 */
export function createDockSizeController({ doc, viewportWidth, columnWidth, onFallback }) {
  let requested = "compact"
  let fallback = false
  let size = "compact"

  const decide = () => {
    const resolved = resolveDockSize(requested, {
      viewportWidth: viewportWidth(),
      minColumnsWidth: minColumnsWidth(columnWidth())
    })

    size = resolved.size

    const root = documentRoot(doc)
    if (root) root.dataset.dockSize = size

    if (resolved.fallback !== fallback) {
      fallback = resolved.fallback
      if (onFallback) onFallback(fallback)
    }
  }

  return {
    set(next) {
      requested = normalizeDockSize(next)
      decide()
    },
    refresh: decide,
    get size() {
      return size
    },
    get requested() {
      return requested
    }
  }
}

function documentRoot(doc) {
  return (doc && doc.documentElement) || null
}
