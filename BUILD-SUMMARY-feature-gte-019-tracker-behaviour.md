# gte-019 — Tracker behaviour + None adapter

Task: gte-019
Branch: `feature/gte-019-tracker-behaviour`

## What

Defines the `Arbiter.Trackers.Tracker` behaviour (the contract every external
issue-tracker adapter implements) and ships the trivial `Tracker.None` adapter
for workspaces with no external tracker.

`Arbiter.Trackers` is the entry point: it reads `issue.tracker_type`,
resolves the adapter, and delegates. Callers don't manually pick adapters.

This unblocks gte-020+ (Jira adapter in Phase 3) and the Linear/GitHub
adapters in Phase 5.

## Files

- `apps/arbiter/lib/arbiter/trackers/tracker.ex` — the `@behaviour`
  module with six callbacks: `fetch`, `transition`, `update_fields`,
  `link_for`, `parse_ref`, `list_transitions`. Doc-comments describe the
  contract for each.
- `apps/arbiter/lib/arbiter/trackers/none.ex` — `Tracker.None` adapter.
  All callbacks succeed as no-ops. `fetch/1` returns `{:ok, %{}}`,
  `link_for/1` returns `""`, `parse_ref/1` always returns `:error` (None
  never owns a ref), `list_transitions/1` returns the full task-status set.
- `apps/arbiter/lib/arbiter/trackers.ex` — registry + delegating
  wrappers: `for_task/1`, `for_type/1`, `adapters/0`, plus `fetch/1`,
  `transition/2`, `update_fields/2`, `link_for/1`, `list_transitions/1` that
  take an `Issue` and dispatch through `for_task/1`.
- `apps/arbiter/test/arbiter/trackers_test.exs` — 9 tests for resolution
  + delegation.
- `apps/arbiter/test/arbiter/trackers/none_test.exs` — 7 tests for the
  None adapter's callback semantics (including a check that the module
  declares the behaviour attribute).

## Things the reviewer should pay attention to

### 1. Adapter map is intentionally minimal

```elixir
@adapters %{
  none: None
  # :jira, :linear, :github wired up in Phases 3/5
}
```

Asking for `for_type(:jira)` today raises `ArgumentError` with a useful
message ("no tracker adapter registered for :jira (registered: [:none])").
That's deliberate — task create-time already validates `tracker_type` is in
the enum, so this code path is only hit when someone tries to *use* the
tracker on a task whose adapter doesn't exist yet. Loud failure is better
than silently no-op'ing on arb close or PR-link generation.

The Phase 3 work that wires up Jira just needs to add `jira: Arbiter.Trackers.Jira`
to the map (plus the adapter module).

### 2. `Tracker.None.list_transitions/1` returns the full status set

```elixir
def list_transitions(_ref), do: {:ok, [:open, :in_progress, :closed]}
```

For tracker-backed tasks this is restricted (Jira workflows have edges). For
`Tracker.None` the task ledger imposes the only restrictions, which are
already enforced by `GuardStatus` in the Issue resource — so the adapter
reports "anything goes." Callers that want the *task*'s allowed transitions
should ask the Issue, not the tracker.

### 3. Delegating wrappers use `Issue.t()`, not `(adapter, ref)` pairs

The public surface is `Trackers.fetch(issue)`, not `Trackers.fetch(adapter, ref)`.
This is intentional — keeps `tracker_type` resolution centralized so
per-task overrides (the `Workspace.config.tracker.type` → task.tracker_type
inheritance from gte-002) actually take effect at call time. Callers that
need to bypass resolution can use `for_type/1` directly.

### 4. No `Application` registration / supervisor

`Tracker.None` is pure (no state), so it isn't supervised. Future adapters
(`Tracker.Jira`) that need a connection pool or rate-limiter GenServer
should add a supervisor child in `Arbiter.Application.start/2` at that
time, not now. Avoids speculative supervision.

## Test results

```
trackers_test           9 tests, 0 failures
trackers/none_test      7 tests, 0 failures
arbiter              122 tests, 0 failures (106 prior + 16 new)
arbiter_web           36 tests, 0 failures (unchanged)
arbiter_cli           48 tests, 0 failures (unchanged)
total                  206 tests, 0 failures
```

`mix compile --warnings-as-errors` clean.
`mix format --check-formatted` clean.

## Follow-ups (not in this PR)

- gte-020 / gte-029 (Jira adapter): the Markdown → ADF helper already exists
  from prior GT work; the Jira adapter wires it up to `update_fields/2`.
- The `Tracker.None` `list_transitions` returning all-statuses is technically
  inaccurate — `:open → :closed` is illegal per the task FSM (you go through
  `:in_progress` or use the dedicated `:close` action). But the *tracker*
  doesn't know that; the task-ledger does. If we want a unified API later we
  can have callers AND the task FSM both consulted.
- No integration test wiring Trackers through an actual Issue create/close —
  Phase 1 already covers Issue lifecycle, and the unit tests cover the
  delegation. Will add a real round-trip test when Jira lands.
