// The terminal's copy/paste bindings, under `node --test` (bd-3r2otb,
// acceptance criterion 3).
//
// Two things went wrong in the live check and both are one line of policy
// each, which is why they now live in a DOM-free module of their own:
//
//   - `Ctrl+Shift+C` returned `false` (telling xterm to keep out) but never
//     called `preventDefault()`, so the browser went ahead and opened its
//     own devtools inspector on top of the dashboard;
//   - `Ctrl+Shift+V` *did* call `preventDefault()`, which also cancels the
//     browser's own "paste as plain text" — so on any page where
//     `navigator.clipboard.readText()` is unavailable (an insecure origin) or
//     refused, the binding cancelled the only paste that would have worked
//     and silently did nothing.
//
//   node --test apps/arbiter_web/test/js/session_keys_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { handleTerminalKey } from "../../assets/js/session_keys.mjs"

const CLIPBOARD_TEXT = "pasted-from-the-clipboard\nsecond line\n"

function keyEvent(key, { ctrl = false, meta = false, shift = false, type = "keydown" } = {}) {
  return {
    type,
    key,
    ctrlKey: ctrl,
    metaKey: meta,
    shiftKey: shift,
    prevented: false,
    preventDefault() {
      this.prevented = true
    }
  }
}

function fakeTerm(selection = "") {
  return {
    selection,
    pasted: [],
    getSelection() {
      return this.selection
    },
    paste(text) {
      this.pasted.push(text)
    }
  }
}

function fakeClipboard({ read = CLIPBOARD_TEXT, write = true } = {}) {
  const clipboard = { written: [] }

  if (write) {
    clipboard.writeText = async (text) => {
      clipboard.written.push(text)
    }
  }

  if (read !== null) {
    clipboard.readText = async () => {
      if (read instanceof Error) throw read
      return read
    }
  }

  return clipboard
}

// A microtask turn, so the clipboard promises settle.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

test("Ctrl+Shift+C copies the selection and never reaches the browser", async () => {
  const term = fakeTerm("hello red")
  const clipboard = fakeClipboard()
  const event = keyEvent("C", { ctrl: true, shift: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), false)
  await settle()

  assert.equal(event.prevented, true)
  assert.deepEqual(clipboard.written, ["hello red"])
})

test("Cmd+Shift+C copies too", async () => {
  const term = fakeTerm("hello red")
  const clipboard = fakeClipboard()

  assert.equal(handleTerminalKey(keyEvent("C", { meta: true, shift: true }), { term, clipboard }), false)
  await settle()

  assert.deepEqual(clipboard.written, ["hello red"])
})

test("Ctrl+Shift+C is swallowed even with nothing selected", async () => {
  // The whole point of the binding is that the browser never sees it. An empty
  // selection is not a reason to hand the operator an inspector instead.
  const term = fakeTerm("")
  const clipboard = fakeClipboard()
  const event = keyEvent("C", { ctrl: true, shift: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), false)
  await settle()

  assert.equal(event.prevented, true)
  assert.deepEqual(clipboard.written, [])
})

test("Ctrl+Shift+V pastes the clipboard through the terminal", async () => {
  const term = fakeTerm()
  const clipboard = fakeClipboard()
  const event = keyEvent("V", { ctrl: true, shift: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), false)
  await settle()

  // `term.paste`, never the stream: xterm is what turns LF into CR and adds
  // the bracketed-paste markers when the app has asked for them.
  assert.deepEqual(term.pasted, [CLIPBOARD_TEXT])
  assert.equal(event.prevented, true)
})

test("Ctrl+Shift+V falls back to the browser's own paste when the clipboard cannot be read", async () => {
  // No `readText` at all — `navigator.clipboard` is undefined on an insecure
  // origin. Cancelling the event here would cancel the browser's "paste as
  // plain text", which is the only paste left.
  const term = fakeTerm()
  const clipboard = fakeClipboard({ read: null })
  const event = keyEvent("V", { ctrl: true, shift: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), false)
  await settle()

  assert.equal(event.prevented, false)
  assert.deepEqual(term.pasted, [])
})

test("a refused clipboard read is reported rather than silently doing nothing", async () => {
  const term = fakeTerm()
  const clipboard = fakeClipboard({ read: new Error("NotAllowedError") })
  const errors = []

  handleTerminalKey(keyEvent("V", { ctrl: true, shift: true }), {
    term,
    clipboard,
    onClipboardError: (error) => errors.push(String(error))
  })
  await settle()

  assert.deepEqual(term.pasted, [])
  assert.equal(errors.length, 1)
  assert.match(errors[0], /NotAllowedError/)
})

test("plain Ctrl+C is left alone, so it still reaches the agent as SIGINT", () => {
  const term = fakeTerm("hello red")
  const clipboard = fakeClipboard()
  const event = keyEvent("c", { ctrl: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), true)

  assert.equal(event.prevented, false)
  assert.deepEqual(clipboard.written, [])
})

test("plain Ctrl+V is left to the browser's own paste", () => {
  const term = fakeTerm()
  const clipboard = fakeClipboard()
  const event = keyEvent("v", { ctrl: true })

  assert.equal(handleTerminalKey(event, { term, clipboard }), true)

  assert.equal(event.prevented, false)
  assert.deepEqual(term.pasted, [])
})

test("other Ctrl+Shift chords and non-keydown events pass straight through", () => {
  const term = fakeTerm("x")
  const clipboard = fakeClipboard()

  for (const event of [
    keyEvent("A", { ctrl: true, shift: true }),
    keyEvent("C", { shift: true }),
    keyEvent("C", { ctrl: true, shift: true, type: "keyup" }),
    keyEvent("V", { ctrl: true, shift: true, type: "keypress" })
  ]) {
    assert.equal(handleTerminalKey(event, { term, clipboard }), true, `${event.type} ${event.key}`)
    assert.equal(event.prevented, false)
  }
})
