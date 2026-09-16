// The session dock's `localStorage` guards, under `node --test` (bd-dlc136).
//
// The dock's open/expanded state is a browser preference, so it lives in
// `localStorage` — which is the one browser API on this page that can throw
// on *read*, not just on write: Safari in private mode and any browser with
// site data blocked raise a `SecurityError` on the `window.localStorage`
// getter itself, and a full quota raises on `setItem`. The acceptance
// criterion is that empty, blocked or throwing storage renders an empty dock
// rather than a broken page, and a page that throws during `mounted()` takes
// every other hook on it down with it.
//
// So the two functions the hook is made of are DOM-free and tested here
// against fake stores that fail in each of those ways.
//
//   node --test apps/arbiter_web/test/js/session_dock_test.mjs

import test from "node:test"
import assert from "node:assert/strict"

import { DOCK_STORAGE_KEY, readDockState, writeDockState } from "../../assets/js/session_dock.mjs"

const EMPTY = { open: [], expanded: null }

function memoryStore(initial = {}) {
  const data = new Map(Object.entries(initial))
  return {
    data,
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
    removeItem: (k) => data.delete(k)
  }
}

function throwingStore(on) {
  return {
    getItem() {
      if (on === "read") throw new Error("SecurityError")
      return null
    },
    setItem() {
      if (on === "write") throw new Error("QuotaExceededError")
    },
    removeItem() {}
  }
}

test("an empty store reads as an empty dock", () => {
  assert.deepEqual(readDockState(memoryStore()), EMPTY)
})

test("a missing store reads as an empty dock", () => {
  assert.deepEqual(readDockState(null), EMPTY)
  assert.deepEqual(readDockState(undefined), EMPTY)
})

test("a store that throws on read reads as an empty dock", () => {
  assert.deepEqual(readDockState(throwingStore("read")), EMPTY)
})

test("unparseable or wrongly-shaped contents read as an empty dock", () => {
  for (const raw of [
    "not json",
    "null",
    "[]",
    '"a string"',
    "42",
    '{"open":"nope"}',
    '{"open":{"0":"a"}}'
  ]) {
    assert.deepEqual(
      readDockState(memoryStore({ [DOCK_STORAGE_KEY]: raw })),
      EMPTY,
      `for ${raw}`
    )
  }
})

test("a well-formed payload round-trips", () => {
  const store = memoryStore()
  writeDockState(store, { open: ["a", "b"], expanded: "b" })

  assert.deepEqual(readDockState(store), { open: ["a", "b"], expanded: "b" })
})

test("non-string entries and a non-string expanded id are dropped on read", () => {
  const raw = JSON.stringify({ open: ["a", 7, null, "b", { x: 1 }], expanded: 12 })

  assert.deepEqual(readDockState(memoryStore({ [DOCK_STORAGE_KEY]: raw })), {
    open: ["a", "b"],
    expanded: null
  })
})

test("an expanded id that is not open is dropped on read", () => {
  const raw = JSON.stringify({ open: ["a"], expanded: "b" })

  assert.deepEqual(readDockState(memoryStore({ [DOCK_STORAGE_KEY]: raw })), {
    open: ["a"],
    expanded: null
  })
})

test("a store that throws on write is survivable and changes nothing", () => {
  assert.doesNotThrow(() => writeDockState(throwingStore("write"), { open: ["a"], expanded: "a" }))
  assert.doesNotThrow(() => writeDockState(null, { open: [], expanded: null }))
})

test("writing a malformed state does not poison the store", () => {
  const store = memoryStore({ [DOCK_STORAGE_KEY]: JSON.stringify({ open: ["a"], expanded: "a" }) })

  writeDockState(store, undefined)
  writeDockState(store, { open: "nope", expanded: 3 })

  assert.deepEqual(readDockState(store), EMPTY)
})
