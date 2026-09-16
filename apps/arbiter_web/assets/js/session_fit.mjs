// How many whole cells fit in the pane (bd-3r2otb, acceptance criterion 2).
//
// This replaces `@xterm/addon-fit`, which is wrong for this page. The addon
// sizes the terminal from `getComputedStyle(parent).height`, and Chrome
// resolves that to the **border box** whenever `box-sizing: border-box` is in
// force — which, under Tailwind's preflight, is everywhere. The session pane
// is `h-[min(70vh,640px)] p-2`, so its 16px of padding was counted as usable
// terminal space: with a 20px cell the fit asked for exactly one row more than
// the box could show, and the bottom line of the agent's UI — Claude Code's
// footer — was clipped in half.
//
// Kept DOM-free so `apps/arbiter_web/test/js/session_fit_test.mjs` can drive
// the arithmetic under `node --test`, for the same reason `session_stream.mjs`
// is: the interesting failures here are off-by-one and rounding, and a browser
// makes those invisible.

// xterm's own minimums. `Terminal.resize` below these is not a smaller
// terminal, it is a broken one.
const MIN_COLS = 2
const MIN_ROWS = 1

/**
 * `{cols, rows}` for a **content box** `width` x `height`, or `null` when the
 * pane has no usable box yet.
 *
 * `null` rather than a clamped `1` row: an unlaid-out container (a background
 * tab, a mount before first paint) is not a one-row terminal, and this
 * geometry is pushed to the server, where it resizes the pane that *every*
 * attached client shares.
 */
export function fitGeometry({
  width,
  height,
  cellWidth,
  cellHeight,
  scrollbarWidth = 0,
  minCols = MIN_COLS,
  minRows = MIN_ROWS
}) {
  if (!positive(width) || !positive(height)) return null
  if (!positive(cellWidth) || !positive(cellHeight)) return null

  return {
    cols: Math.max(minCols, Math.floor((width - scrollbarWidth) / cellWidth)),
    rows: Math.max(minRows, Math.floor(height / cellHeight))
  }
}

function positive(value) {
  return Number.isFinite(value) && value > 0
}

// The number of animation frames a mount will wait for its container to get a
// box before giving up and connecting anyway. ~20 frames is a third of a
// second at 60Hz: long enough for a LiveView patch, a webfont swap and a
// scrollbar appearing, short enough that a genuinely hidden pane (a background
// tab, which never paints at all) still attaches promptly.
const SETTLE_FRAMES = 20

/**
 * Measure until the pane has a box, then report it — once (bd-14b11h).
 *
 * The mount-time fit cannot be a single synchronous measurement. On a LiveView
 * navigation the hook's `mounted()` runs inside the DOM patch, and the pane it
 * is handed can still be 0x0; `fitGeometry` correctly refuses to size that, and
 * the old code simply gave up, leaving xterm on its 80x24 construction default.
 * That default is not inert: it is what the join's `cols`/`rows` carry, so it
 * resizes the pane *every* attached client shares and the snapshot captured in
 * the same breath is reflowed for a geometry the agent has not redrawn at.
 *
 * `measure` returns a geometry or `null`. `onSettled` is called exactly once,
 * with the first geometry that measured, or with `null` when the budget ran
 * out — the caller still has to connect either way. `schedule` is
 * `requestAnimationFrame` in the browser and a list in the tests.
 *
 * Returns a `cancel()`: a hook that is navigated away from mid-settle must not
 * come back to life and resize a pane it no longer owns.
 */
export function settleFit({
  measure,
  schedule,
  onSettled = () => {},
  frames = SETTLE_FRAMES
}) {
  let cancelled = false
  let left = frames

  const attempt = () => {
    if (cancelled) return

    const geometry = measure()

    if (geometry) {
      cancelled = true
      onSettled(geometry)
      return
    }

    if (left <= 0) {
      cancelled = true
      onSettled(null)
      return
    }

    left -= 1
    schedule(attempt)
  }

  attempt()

  return () => {
    cancelled = true
  }
}
