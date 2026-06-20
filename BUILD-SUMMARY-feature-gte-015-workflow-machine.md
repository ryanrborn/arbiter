# gte-015 — WorkflowMachine GenStateMachine

**Branch:** `feature/gte-015-workflow-machine`
**Base:** `main @ 7cf11b4`
**Commits:** 2 (impl+tests, BUILD-SUMMARY)
**Test delta:** +14 tests (apps/arbiter: 231 → 245), full umbrella green
**Quality gates:** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`

## What landed

| Module                                       | Role                                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `Arbiter.Workflows`                         | Ash domain (sibling of `Arbiter.Tasks` — workflows are not tasks).                        |
| `Arbiter.Workflows.MachineState`            | Ash resource. One row per workflow instance. Stores status, current step, threaded state. |
| `Arbiter.Workflows.Machine`                 | The driver. `GenStateMachine` (`:handle_event_function`).                                  |
| `Arbiter.Workflows.MachineRegistry`         | Thin `Registry` wrapper. Keyed by MachineState id.                                         |
| Migration `20260520144412`                   | `workflow_machine_states` table + indexes on `task_id`, `status`.                          |
| Dep                                          | `{:gen_state_machine, "~> 3.0"}`                                                           |

## Public API

```elixir
Machine.attach(workflow_module, task_id, vars) :: {:ok, id} | {:error, :not_a_workflow | :unknown_module | ash_err}
Machine.start(id)                              :: {:ok, pid} | {:error, term}
Machine.whereis(id)                            :: pid | nil
Machine.current_step(ref)                      :: atom
Machine.status(ref)                            :: :idle | :running | :paused | :completed | :failed
Machine.state_data(ref)                        :: map
Machine.advance(ref)                           :: {:ok, atom | :completed} | {:error, term}
Machine.pause(ref) / Machine.resume(ref)       :: :ok | {:error, term}
Machine.stop(ref, reason)
```

`ref` is a binary id (UUID v7) or a pid. Binary refs that don't resolve to a registered pid return `nil` (queries) or `{:error, :not_found}` (commands).

## FSM states (mirror of `:status`)

```
:idle  ──advance──► :running ──advance──► :running
                       │                       │
                       │ all done              │ run_step => {:error, _}
                       ▼                       ▼
                  :completed                :failed
                       ▲                       ▲
                       │                       │
                       └── pause ⇄ resume ─────┘
                              (:paused)
```

`advance/1` while `:paused` returns `{:error, :paused}`. While `:completed` returns `{:error, :already_done}`. While `:failed` returns `{:error, :already_failed}`. Pause is idempotent from `:paused`; rejected from terminal states.

## Three reviewer items

### 1. `Module.safe_concat/1` allowlist

`workflow_module` is persisted as a string (`"Arbiter.TestWorkflows.Three"`). On `start/1`, `load_workflow_module/1` does:

```elixir
mod = Module.safe_concat([name])        # raises only on bad atom shape, never *creates*
validate_workflow_module(mod)           # rejects unless Arbiter.Workflow ∈ behaviours
```

`safe_concat` will not load arbitrary code: the atom must already exist (which means the module must already be compiled into the BEAM). The behaviour check enforces the allowlist — any module compiled into the build that declares `@behaviour Arbiter.Workflow` is acceptable; everything else returns `{:error, :not_a_workflow}`. The attacker surface is "drop a module into the build that already declares the Workflow behaviour", which is the same surface as "drop code anywhere".

A test (`attach rejects a module that does not implement Arbiter.Workflow`) hits the negative path; another (`attach rejects a non-existent module`) hits the `:unknown_module` case.

### 2. Per-transition DB write

Every advance writes the entire `MachineState` row back via `Ash.update/2` **before** replying to the caller. This includes the no-op path (`pause`/`resume` writes `status`). Rationale:

- **Correctness first.** Crash-recovery test passes trivially because in-memory and on-disk state agree at every observable boundary.
- **Throughput is N+1.** For a 3-step workflow we do 3 writes. For a 100-step workflow we do 100. Fine at our scale; flagged in the moduledoc for Phase 5 batching when measurement shows it.
- **No write coalescing.** Considered queueing writes and flushing on idle, decided correctness > throughput at this phase. The single write is on the call path so callers see persisted state on return.

### 3. `gen_state_machine` vs `GenServer`

Used `gen_state_machine` (`:handle_event_function` callback mode) rather than `GenServer`. Reasoning:

- The status field IS the FSM state — having BEAM dispatch by state head (`handle_event({:call, _}, :advance, :paused, _)`) matches `Polecat`'s `def handle_call({:advance, ...}, _, %State{status: :paused})` pattern from gte-011 and reads cleanly. Both are valid; `gen_state_machine` is honest about being an FSM.
- `Polecat` uses `GenServer` with status-in-data. Both modules now exist side by side, and the two styles can be A/B'd by readers.
- We did NOT use `:state_functions` callback mode — it requires state names to be function names, and our FSM is small enough that single dispatch reads better than five module-level functions.

The single user-visible cost is two warnings in the `gen_state_machine` dep itself (deprecated `List.zip/1`, charlist syntax). These are deps, not us, so they don't trip `--warnings-as-errors`.

## Task ↔ workflow_module cardinality

**1 task : N machines.** A task can have multiple machine rows over time (different workflows applied sequentially, one re-run after a failure, etc.). Each is a distinct `id`. We do not enforce a `unique (task_id, workflow_module)` constraint — the caller decides whether re-attaching makes sense in their domain. Documented on `MachineState`'s moduledoc.

We also did not make `task_id` an Ash relationship. The Workflows domain stays independent of Tasks — a Machine that needs to read its task does so at runtime via `Ash.get(Issue, task_id)`. If the task row is later deleted, the Machine row survives; reads will fail loudly. Acceptable since tasks are append-only in practice.

## Test coverage (14 tests, all DB-backed via `Arbiter.DataCase, async: false`)

- attach: creates row in `:idle` w/ first step
- attach: rejects non-workflow module
- attach: rejects unknown module
- advance: executes `:a`, persists, `current_step → :b`
- advance: 3 sequential advances complete the workflow
- advance: after `:completed` returns `{:error, :already_done}`
- advance: state threading correct across all 3 steps
- failure: `run_step` returns `{:error, _}` → status `:failed`, error_reason captured
- pause: rejects advance with `{:error, :paused}`; resume + advance proceeds
- crash + restart: `Process.exit(pid, :kill)`, then `start(id)` with same id resumes at the right step with the right state
- unmet needs: forging `completed_steps == []` while `current_step == :b` → `{:error, {:unmet_needs, [:a]}}`
- whereis: nil for unknown, pid for running
- registry: two machines for different tasks coexist
- start: `{:error, {:already_started, pid}}` when called twice with same id

## Constraints honored

- Two commits (impl+tests, BUILD-SUMMARY).
- Conventional `feat(gte-015):` prefix.
- No `--no-verify`.
- Stopped at the branch — no merge, no push.
