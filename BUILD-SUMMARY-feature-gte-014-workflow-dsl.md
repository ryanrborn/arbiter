# gte-014 — Workflow behaviour + macro DSL

Bead: gte-014
Branch: `feature/gte-014-workflow-dsl`

## What

Defines the `Arbiter.Workflow` behaviour and the macro DSL that lets
"formulas" (the Elixir port of the Go GT YAML workflow templates like
`mol-polecat-work` and `mol-polecat-code-review`) be declared as plain Elixir
modules:

```elixir
defmodule Examples.Boring do
  use Arbiter.Workflow,
    steps: [:greet, :wave]

  step :greet, description: "Say hi", needs: [], vars: [:name]
  step :wave, description: "Wave goodbye", needs: [:greet], vars: []

  @impl Arbiter.Workflow
  def run_step(:greet, %{name: name} = state), do: {:ok, ...}
  def run_step(:wave, state), do: {:ok, ...}
end
```

Also exposes a runner, `Arbiter.Workflow.run(workflow_module, initial_state)`,
that drives the steps in declared order, threads state, populates
`:completed_steps`, and validates `needs:` at runtime before invoking
`run_step/2`.

This unblocks Phase 2/3 work that needs to express polecat workflows
(implement, design, review, submit) without rewriting Go YAML in Elixir
strings.

## Files

- `apps/arbiter/lib/arbiter/workflow.ex` — behaviour callbacks
  (`steps/0`, `step_definition/1`, `vars/0`, `run_step/2`), `__using__/1`
  macro, `step/2` macro, `__before_compile__/1` for validation + clause
  generation, and the runner `run/2`.
- `apps/arbiter/lib/arbiter/workflow/example.ex` — `GreetThenWave`, a
  trivial 2-step example that exercises the macro at top-level umbrella
  compile time (not just in tests).
- `apps/arbiter/test/arbiter/workflow_test.exs` — 16 tests across four
  groups: behaviour callbacks, Phase 5 placeholder shape, the runner, and
  compile-time validation (the latter via `Code.compile_string/1` on
  intentionally-bad module strings).

## Things the reviewer should pay attention to

### 1. `@before_compile` over inline clause generation

`step :name, opts` accumulates `{name, opts}` into `@__workflow_step_definitions`;
clauses for `step_definition/1` are generated in `@before_compile`. The
tradeoff:

- **Inline** (emit a `def step_definition(:name)` clause directly from the
  `step` macro) is simpler but makes the cross-step validations (orphan
  declarations, `needs:` referencing unknown steps, `vars/0` union) awkward
  — you don't have the whole picture until all `step` calls have run.
- **`@before_compile`** keeps the macro DSL surface area minimal (`step/2`
  is a one-liner attribute push) and centralizes all validation in one
  place. All three compile-time errors live there with consistent message
  format. Worth the slight indirection.

The accumulator is reversed before use (accumulating attributes come back in
reverse insertion order in Elixir).

### 2. `needs:` enforcement is both compile-time AND runtime

- **Compile-time**: a step's `needs:` list must reference atoms that appear
  in `steps:`. Catches typos. Does *not* check ordering — a step can
  legally declare it needs a step that comes later in the list (which then
  blows up at runtime, see below).
- **Runtime**: `run/2` checks `state.completed_steps` against the step's
  `needs:` *before* invoking `run_step/2`. An unmet need returns
  `{:error, {step, {:unmet_needs, missing}}}` without running the step.
  This is what catches the "needs a later step" misorder.

The runtime check exists because a future Phase 5 composition (expansions,
aspects) could rearrange steps in ways that re-violate ordering — keeping
the runtime guard ensures it stays a real safety net rather than an
artifact of the original declaration.

### 3. Compile-time error messages

All three compile-time failures raise `CompileError` with a single
`description:` string that includes:
- The offending module name (via `inspect(module)`)
- The category ("missing `step :name, ...` definition(s)" / "not in
  `steps:` list" / "needs: ... but ... are not in `steps:`")
- The exact bad atom(s) so a reader can ctrl-F the source

Example:

```
Arbiter.Workflow Arbiter.WorkflowTest.UnknownNeed: step :b declares
needs: [:phantom] but [:phantom] are not in `steps:`
```

Tested with `Code.compile_string/1` on bad-shaped modules.

### 4. Phase 5 placeholder shape

`use Arbiter.Workflow` accepts three options today that aren't processed:

```elixir
use Arbiter.Workflow,
  steps: [...],
  extends: SomeOtherWorkflow,           # a module
  expansions: [tdd_cycle: :implement],  # keyword: aspect_name => target_step
  aspects: [security_audit: :submit]    # keyword: aspect_name => target_step
```

They get stored on the module as `@__workflow_extends`,
`@__workflow_expansions`, `@__workflow_aspects` and exposed via
`__workflow_extends__/0` etc. — Phase 5 can iterate the keyword lists and
look up the target steps without changing the surface API.

There is a `# TODO Phase 5:` comment in `__using__/1` listing the intended
semantics for each option. The placeholder is *just* storage today — no
processing, no warnings about unused options.

### 5. `:completed_steps` semantics

The runner adds `:completed_steps` to state if absent (initialized to `[]`)
and appends each step name *after* a successful `run_step/2` returns. The
user's `run_step/2` is free to mutate other keys; the runner overwrites
`:completed_steps` deterministically based on its own bookkeeping (it reads
whatever the step returned for that key, then appends the step name).

## Test results

```
workflow_test          16 tests, 0 failures (new)
arbiter             167 tests, 0 failures (151 prior + 16 new)
arbiter_web          36 tests, 0 failures (unchanged)
arbiter_cli          48 tests, 0 failures (unchanged)
total                 251 tests, 0 failures
```

`mix compile --warnings-as-errors` clean.
`mix format --check-formatted` clean on the new files.

## Follow-ups (not in this PR)

- **Phase 5 composition**: actually process `extends:` (merge parent's
  `steps:` + `step` definitions), `expansions:` (splice a sub-workflow's
  steps in at the named step), and `aspects:` (run an aspect module's
  before/after hooks around the target step). The data shape is already
  correct; Phase 5 just needs the implementation.
- **Cycle detection in `needs:`**: today we only check that referenced
  step names *exist*. A cycle (`:a needs :b`, `:b needs :a`) would be
  caught at runtime as `{:unmet_needs, ...}` for whichever step runs
  first, but a compile-time topological check would be friendlier.
- **DAG ordering**: today `steps:` is the source of truth for run order;
  `needs:` is a check, not a sort key. A future iteration could optionally
  topo-sort from `needs:` and treat `steps:` as a hint.
- **Variable resolution**: `vars/0` returns the union of all `:vars` opts,
  but nothing validates that the initial state actually provides them.
  Phase 2 polecat runner will likely want a `validate_state/1` helper.
