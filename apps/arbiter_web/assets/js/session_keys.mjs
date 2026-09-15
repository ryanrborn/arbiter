// §6.3's copy/paste bindings (bd-3r2otb, acceptance criterion 3).
//
// `Ctrl/Cmd+Shift+C` copies the selection and `Ctrl/Cmd+Shift+V` pastes, so
// that plain `Ctrl+C` still sends SIGINT to the agent — the single most common
// terminal papercut, and the one that matters most when the thing on the other
// end is an agent mid-turn.
//
// DOM-free, and injected with everything it touches, so
// `apps/arbiter_web/test/js/session_keys_test.mjs` can drive every branch
// under `node --test`. The live check found both branches wrong in opposite
// directions — one cancelled nothing, the other cancelled too much — and
// neither showed up in a renderer test.

/**
 * The handler xterm's `attachCustomKeyEventHandler` wants: `false` means
 * "xterm, keep out of this one", `true` means "this is an ordinary keystroke".
 *
 * `deps` is `{term, clipboard, onClipboardError}` — `clipboard` is
 * `navigator.clipboard` (or undefined, on an insecure origin).
 */
export function handleTerminalKey(event, { term, clipboard, onClipboardError = () => {} }) {
  if (event.type !== "keydown") return true
  if (!(event.ctrlKey || event.metaKey) || !event.shiftKey) return true

  const key = String(event.key || "").toLowerCase()

  if (key === "c") {
    // `preventDefault` unconditionally, including with an empty selection:
    // without it Chrome opens its devtools element inspector over the
    // dashboard, which is what this binding exists to stop. Returning `false`
    // alone does not do it — that only tells *xterm* to keep out.
    event.preventDefault()

    const selection = term.getSelection()
    if (selection && clipboard && clipboard.writeText) {
      Promise.resolve(clipboard.writeText(selection)).catch(onClipboardError)
    }

    return false
  }

  if (key === "v") {
    // Chrome and Firefox bind `Ctrl+Shift+V` themselves ("paste as plain
    // text") and fire a *real* paste event at xterm's helper textarea, which
    // xterm handles on its own. So there are two working paths, and only one
    // of them survives a `preventDefault()`:
    //
    //   - if the async clipboard is readable, take it ourselves and cancel the
    //     browser's, or the text lands twice;
    //   - if it is not — `navigator.clipboard` is undefined outside a secure
    //     context — cancel nothing and let the browser's own paste through.
    //     This is the branch that was missing: the binding cancelled the only
    //     paste that would have worked and then quietly failed to read the
    //     clipboard, so `Ctrl+Shift+V` did nothing at all.
    //
    // Either way `false`, so xterm does not *also* send ^V as a keystroke.
    if (!clipboard || !clipboard.readText) return false

    event.preventDefault()

    Promise.resolve(clipboard.readText())
      .then((text) => {
        // `term.paste()`, never the stream directly. xterm applies the two
        // transformations that make a multi-line paste work at all, and both
        // matter when the thing on the other end is a raw-mode TUI:
        //   - `\r\n`/`\n` -> `\r`, because a raw-mode reader takes CR, not LF,
        //     as Enter;
        //   - bracketed-paste markers (`ESC[200~`/`ESC[201~`) when the app has
        //     enabled the mode, so a pasted prompt is inserted as one block
        //     rather than submitted line by line.
        // It then emits the result through `onData` -> `stream.send`, which
        // chunks it: a paste is not a keystroke and a 200 KB one must not
        // become a single socket frame.
        if (text) term.paste(text)
      })
      // A refusal is reported, never swallowed: "nothing happened" is the one
      // outcome an operator cannot debug.
      .catch(onClipboardError)

    return false
  }

  return true
}
