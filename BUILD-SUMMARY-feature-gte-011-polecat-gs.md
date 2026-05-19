# Build summary: feature/gte-011-polecat-gs

**Bead:** gte-011
**Builder:** Mayor (interactive session, 2026-05-19)
**Branch:** feature/gte-011-polecat-gs
**Commit:** 48227ab (impl + tests)

## What I built

`GtElixir.Polecat` — a per-bead supervised `GenServer` skeleton with a
status FSM, registry lookup by bead_id, and a clean transition API. This is
the Phase 2 lifecycle plumbing; the workflow driver that actually walks
steps ships separately (gte-014 / later phase).

### Files added

```
apps/gt_elixir/lib/gt_elixir/polecat.ex            (+) ~315 LOC
apps/gt_elixir/lib/gt_elixir/polecat/registry.ex   (+) ~30 LOC
apps/gt_elixir/test/gt_elixir/polecat_test.exs     (+) 24 tests
```

### Files modified

```
apps/gt_elixir/lib/gt_elixir/application.ex
  + {Registry, keys: :unique, name: GtElixir.Polecat.Registry}
  + {DynamicSupervisor, strategy: :one_for_one,
                        name: GtElixir.Polecat.Supervisor}
```

### Public API

```elixir
GtElixir.Polecat.start(opts)                       # spawn under DynamicSupervisor
GtElixir.Polecat.start_link(opts)                  # raw entry point
GtElixir.Polecat.whereis(bead_id)                  # pid | nil
GtElixir.Polecat.state(ref)                        # snapshot map | nil
GtElixir.Polecat.advance(ref, step)                # change current workflow step
GtElixir.Polecat.await(ref, reason \\ nil)         # park (waiting on external event)
GtElixir.Polecat.resume(ref)                       # un-park
GtElixir.Polecat.complete(ref, result \\ nil)      # terminal: success
GtElixir.Polecat.fail(ref, reason \\ nil)          # terminal: failure
GtElixir.Polecat.report(ref, key, value)           # write to :meta
GtElixir.Polecat.stop(ref, reason \\ :normal)
```

`ref` is either a pid or a bead_id string. String lookups go through the
registry; if no polecat is registered, the call returns `{:error, :not_found}`
(or `nil` for `state/1`, which the spec called out explicitly).

### Status FSM

```
:idle      --advance/2-->     :running
:running   --advance/2-->     :running    (step change, stays running)
:running   --await/2-->       :awaiting
:awaiting  --resume/1-->      :running
:running   --complete/2-->    :completed
:running   --fail/2-->        :failed
:awaiting  --fail/2-->        :failed
```

All other transitions return `{:error, {:invalid_transition, from, to}}`.
The FSM is enforced in `handle_call/3` pattern-match heads, not in a guard
helper — this keeps the legal transitions readable as a flat list rather
than a `case` ladder.

## Design choices worth flagging

### 1. Explicit verbs over sentinel atoms (the bead asked us to pick)

The bead offered two API shapes:

- `advance(pid, :__awaiting__)` / `advance(pid, {:complete, result})` — one
  entry point, sentinel atoms or tagged tuples for lifecycle changes.
- Split API: `advance/2` (step changes only), plus `await`, `resume`,
  `complete`, `fail`.

**I picked the split API.** Reasons:

- `advance/2`'s type signature gets to be honest: it changes the workflow
  *step*, never the lifecycle *status* directly (other than the initial
  `:idle → :running` bump, which is a side effect of "first step ever
  started"). Without sentinels, the function does one thing.
- Each verb has a single dispatch in `handle_call/3`. Status-FSM violations
  fall out of pattern matching rather than a `case` switch inside a sentinel
  handler.
- Callers read better: `Polecat.await(pid, :pr_review)` vs
  `Polecat.advance(pid, {:await, :pr_review})`. The latter conflates "I am
  moving the workflow forward" with "I am parking."
- Step names are free-form atoms (`:load`, `:design`, `:implement`, …) and
  can't accidentally collide with sentinel names, since sentinels don't
  exist.

The bead's "recommend this" hint pointed in the same direction.

### 2. Supervisor restart strategy: `:temporary`

Each polecat's child_spec uses `restart: :temporary`. The reasoning the bead
gave is correct: a polecat is a workflow runner, not a service. If it
crashes, its in-memory workflow state is gone; restarting the GenServer
would resurrect a process with no idea what step it was on, and the
orchestrator would have to detect this and reconcile. Better to surface the
crash as a definitive "this workflow died" signal and let the next layer
(gte-012 polecat-driver, gte-014 Workflow behaviour) decide whether to
re-spawn from scratch.

A direct consequence is the "supervisor behavior" test: after
`Process.exit(pid, :kill)`, `Polecat.whereis(bead_id)` returns `nil` rather
than a new pid.

### 3. `state/1` returns a snapshot map, not the internal `%State{}`

The spec was explicit: "NOT the GenServer state struct verbatim; a stable
shape." `GtElixir.Polecat.State` is `defmodule …, do: @moduledoc false`
and not exported. Callers see a flat `%{bead_id, workspace_id, rig,
current_step, status, started_at, step_started_at, meta}` map. We can
evolve the internal struct without breaking consumers.

### 4. `await/2` and `complete/2` and `fail/2` stash their argument in `:meta`

- `await(pid, :pr_review)` → `meta[:await_reason] = :pr_review`
- `complete(pid, result)`  → `meta[:result] = result`
- `fail(pid, reason)`      → `meta[:failure_reason] = reason`

`resume/1` deletes `:await_reason`. This is opportunistic — none of the
workflow scaffolding is in place yet, and `:meta` is the spec's blessed
catchall. If gte-014 wants first-class fields it can promote them.

### 5. `report/3` accepts atom OR string keys

The spec says `key, value`; I left the typespec as `atom() | String.t()`.
The internal map happily holds either. No filtering, no transformation —
the orchestrator owns its own key conventions.

### 6. `mix format` flagged pre-existing files

`mix format --check-formatted` against the whole repo flags two migration
files in `apps/gt_elixir/priv/repo/migrations/` that pre-date this branch.
My added files all pass `mix format --check-formatted`. I deliberately did
not reformat the migrations — not part of this bead, and migrations are
sensitive (they're database history).

## Test coverage

24 tests, broken down by describe block:

| Block | Count | Covers |
|---|---|---|
| `start/1 + lifecycle` | 6 | start succeeds, registry lookup, defaults, `state/1` accepts bead_id, unknown bead_id returns nil, missing `:bead_id`, missing `:rig`, duplicate bead_id → `:already_started` |
| `advance/2` | 4 | `:idle → :running`, sequential advances keep `:running`, bead_id ref, unknown bead_id |
| `await / resume` | 4 | `await` from `:running`, `resume` from `:awaiting`, illegal `await` from `:idle`, illegal `resume` from `:running` |
| `complete / fail` | 5 | `complete` from `:running`, `advance` after `complete` rejected, `fail` from `:running`, `fail` from `:awaiting`, illegal `complete` from `:idle` |
| `report/3` | 1 | multiple reports accumulate in `:meta` |
| `stop/2` | 3 | stop by pid, stop by bead_id, stop unknown |
| `supervisor behavior` | 1 | crash does NOT restart (verifies `restart: :temporary`) |

`async: false` because the registry and supervisor are singletons. Each
test generates a unique bead_id via `System.unique_integer/1` so cases
don't collide on the registry; `on_exit` cleans up any lingering
processes.

## Verification

```
mix compile --warnings-as-errors    # clean
mix test apps/gt_elixir/test/gt_elixir/polecat_test.exs   # 24 / 0 failures
mix test                            # umbrella: 259 tests, 0 failures
                                    # (gt_elixir 175, gt_elixir_cli 48, gt_elixir_web 36)
```

## What's NOT in this bead

- No Workflow behaviour. That's gte-014 (parallel).
- No driver that calls `advance / await / complete` based on a workflow
  definition. That's a later phase.
- No persistence. The polecat's state is purely in-process. If we crash,
  it's gone — that's the explicit design.
- No integration with the worktree (gte-009) or branch namer (gte-010).
  Future bead.
- No telemetry/logging. Will land when the driver lands.

## For the reviewer

The three things most worth scrutinizing:

1. **The split-API choice** (`await/resume/complete/fail` vs sentinel
   atoms on `advance`). The reasoning is above; the alternative is
   defensible too. If you want sentinels, this is the moment to push back.
2. **`restart: :temporary`.** If the orchestrator is supposed to treat
   GenServer crashes as recoverable, this is wrong. My read of the bead is
   it's not — crashes are workflow failure events. Confirm.
3. **The snapshot shape returned by `state/1`.** This is what every
   downstream consumer will pattern-match against. Lock it in or push for
   changes now; later changes are breaking.
