// Who owns the pane's size when more than one client is watching it
// (bd-4tjw34).
//
// A session's real geometry is its single tmux pane. Every attached browser
// client fits its own container and pushes the result, and the server applies
// it outright — last writer wins — then tells every client what the pane is
// now (`meta`). So two clients of different sizes disagree by construction:
// the one that did not cause the change is left rendering a screen the pane no
// longer has, garbled until a manual resize or a reload.
//
// The settled policy has two halves, and the second is the one that makes the
// first safe:
//
//   * **Adopt.** A `meta` whose geometry is not the one this client is showing
//     is applied to this client's terminal, whatever it is. Rendering at the
//     pane's real geometry is the only way to render correctly, even if that
//     means letterboxing inside a container that would fit more.
//
//   * **Re-assert only on interaction.** A client pushes its own fitted
//     geometry back *only* when the operator does something to it — focus or a
//     keypress in the terminal, expanding its dock window, a size preset, a
//     browser resize. Never on receiving `meta`, and never because a layout
//     shook out at the same size it already had. Two idle clients would
//     otherwise resize each other for as long as both tabs are open.
//
// That is the whole of it, and it is arithmetic over three geometries, so it
// lives here — DOM-free, driven by `apps/arbiter_web/test/js/session_geometry_test.mjs`
// under `node --test`, for the same reason `session_stream.mjs` is: the
// failure mode is a *loop*, and a loop is what a browser makes impossible to
// assert on. `session_terminal.mjs` is the half that measures and resizes.

/**
 * The three geometries one client has to keep apart.
 *
 *   `own`      what this client's container last measured — what it *wants*
 *   `applied`  what its terminal is currently rendering at
 *   `pane`     what the shared pane is believed to be
 *
 * They are the same number almost always, and the bug is entirely in the
 * moments they are not.
 */
export class PaneGeometry {
  constructor() {
    this._own = null
    this._applied = null
    this._pane = null
  }

  get own() {
    return copy(this._own)
  }

  get applied() {
    return copy(this._applied)
  }

  get pane() {
    return copy(this._pane)
  }

  /** Is this client rendering at somebody else's size rather than its own? */
  get adopted() {
    return !!(this._own && this._pane && !same(this._own, this._pane))
  }

  /**
   * A fresh measurement of this client's own container.
   *
   * `{apply, announce}` — either may be `null`, and `announce` being `null` is
   * the whole no-fight guarantee: a measurement that landed where the last one
   * did changes nothing, so an adopted client stays adopted and silent however
   * often its `ResizeObserver` fires.
   *
   * `force` is "the operator interacted with this client": a keypress, focus,
   * an expand, a preset, a browser resize. It re-asserts this client's own
   * geometry even when nothing about the container moved, and it is the *only*
   * thing that reclaims an adopted pane — because adopting is itself a layout
   * change. A terminal resized to a geometry larger than its container puts a
   * scrollbar on the container, the scrollbar takes a row or a column back,
   * and an unforced refit would read that as the operator resizing something
   * and push a new geometry at the pane. Two clients doing that in turn is the
   * ping-pong this whole module exists to prevent, and a real browser found it
   * (`scripts/verify_session_dock_terminal.mjs`). So while this client is
   * adopted, a measurement is *remembered* and nothing else: it is what the
   * next reclaim will ask for, not a reason to ask now.
   */
  fit(measured, { force = false } = {}) {
    const next = geometry(measured)
    if (!next) return { apply: null, announce: null }

    const adopted = this.adopted
    const moved = !same(next, this._own)
    this._own = next

    if (!force && (adopted || !moved)) return { apply: null, announce: null }

    // Optimistic: the push has not been acknowledged, but the pane applies it
    // outright and the `meta` that follows only confirms it. Waiting for that
    // round trip would leave the size label reading "adopted" for a pane this
    // client has just reclaimed.
    this._applied = next
    this._pane = next

    return { apply: copy(next), announce: copy(next) }
  }

  /**
   * What the pane says it is — a `meta` event.
   *
   * There is deliberately no `announce` in the answer. This is the edge a
   * resize fight would have to cross, and it does not exist.
   */
  note(meta) {
    const next = geometry(meta)
    if (!next) return { apply: null }

    this._pane = next

    if (same(next, this._applied)) return { apply: null }

    this._applied = next
    return { apply: copy(next) }
  }
}

function geometry(value) {
  if (!value) return null

  const { cols, rows } = value
  if (!Number.isInteger(cols) || !Number.isInteger(rows)) return null
  if (cols <= 0 || rows <= 0) return null

  return { cols, rows }
}

function same(a, b) {
  return !!a && !!b && a.cols === b.cols && a.rows === b.rows
}

function copy(value) {
  return value ? { cols: value.cols, rows: value.rows } : null
}
