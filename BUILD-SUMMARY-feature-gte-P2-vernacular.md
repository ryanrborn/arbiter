# gte-P2 — Vernacular module + default fallback

Bead: gte-P2
Branch: `feature/gte-P2-vernacular`

## What

`GtElixir.Vernacular` — the read-through layer for workspace-configurable
vocabulary. Internal Elixir module names (`Polecat`, `Refinery`, etc.) stay
stable; user-facing CLI output, dashboards, and templates call this module
to get the right label for the active workspace.

Backed by `Workspace.config["vernacular"]` (the JSON column from gte-P1).
Falls back to the canonical gas-town defaults when a key is unset.

## Files

- `apps/gt_elixir/lib/gt_elixir/vernacular.ex` — module with `label/1`,
  `alias_resolve/1`, `emoji/1`, `put_active/1`, `clear/0`, `defaults/0`,
  `keys/0`.
- `apps/gt_elixir/test/gt_elixir/vernacular_test.exs` — 19 tests.

## Defaults

```elixir
%{
  coordinator: "mayor",
  worker: "polecat",
  merge_queue: "refinery",
  monitor: "witness",
  watchdog: "deacon",
  issue: "bead",
  batch: "convoy",
  rig: "rig",
  epic: "mountain"
}
```

These keys are the entire valid set. `label/1` on an unknown key raises
`KeyError` with a message listing the valid keys.

## Things the reviewer should pay attention to

### 1. Process dictionary for the active workspace

`put_active(workspace_or_config)` stores the config in `Process.dictionary`
under `:gt_elixir_active_vernacular`. Subsequent `label/1` calls in the same
process read from there — no DB roundtrip per lookup.

**Why process dictionary, not ETS / GenServer:** every request handler and
every CLI invocation runs in its own process. The vernacular is bound to
"who is asking" (and which workspace they belong to), so process-scoped
state is the natural fit. ETS would require explicit per-process key
management; a GenServer would serialize lookups behind a single mailbox for
no reason.

**Side effect:** spawned `Task`s do not inherit. The process-scoping test
verifies this. Phoenix request handlers + escript invocations are
single-process and the lookup is cheap, so this is the right tradeoff. If
we later need workflow-level inheritance (a polecat spawning a child task
that needs the same vernacular), we'll either:
- pass the workspace explicitly through the call chain, or
- add a `with_active/2` macro that wraps a block, propagating to spawned
  tasks via the OTP logger metadata pattern.

Documented in the moduledoc.

### 2. No DB lookup, ever — only what callers put

This module never touches the Repo. Callers (Phoenix plug, CLI bootstrap,
polecat startup) are responsible for calling `put_active/1` once with the
workspace they've already loaded. Keeps the module pure-data and unit-test
friendly (the test file has no DataCase, no DB sandbox).

### 3. `alias_resolve/1` always returns a string

```elixir
alias_resolve(:deploy)  # => "sling" or "deploy"
```

CLI argument parsing wants strings, not atoms — returning an atom would
force callers to `Atom.to_string/1` everywhere. Atoms-in, strings-out is
the ergonomic choice for this surface.

### 4. Empty / blank values fall through to defaults

`label(:worker)` with `vernacular["worker"] = ""` returns `"polecat"`, not
`""`. Same for `alias_resolve` and `emoji` — blank values are treated as
"unset" rather than "deliberately empty." This is the user-friendly default;
if someone genuinely wants an empty label they can pass a single space.

### 5. Keys are restricted; emoji subkeys are not

`label(:not_a_thing)` raises. But `emoji(:worker)` is allowed even if the
workspace's emoji map omits `"worker"` — it just returns `""`. The keys
domain is the same for both `label` and `emoji` (the union of `Vernacular.keys()`),
but `emoji` is opt-in per-key whereas `label` always has a default to fall
back to.

## Test results

```
vernacular_test    19 tests, 0 failures
gt_elixir         170 tests, 0 failures (151 prior + 19 new)
total             254 tests, 0 failures across umbrella
```

`mix compile --warnings-as-errors` clean.
`mix format --check-formatted` clean for new files.

## Follow-ups (not in this PR)

- A Plug that calls `put_active/1` from `conn.assigns[:workspace]` (or
  similar) at the start of each Phoenix request. Trivial; deferred to
  whoever wires up the multi-workspace web UI.
- Same for the bd2 CLI bootstrap — `apps/gt_elixir_cli` already resolves
  the active workspace; it should call `Vernacular.put_active/1` right
  after. Filing as a quick gte-P2.5 follow-up bead if desired.
- Aliases currently affect only one direction (verb → alias). If we want
  the reverse (alias → verb) for parsing user input, add an
  `alias_canonical/1` companion. Defer until the CLI actually needs it.
