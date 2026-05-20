# gte-023 — MergeQueue / Refinery GenServer

Bead: gte-023
Branch: `feature/gte-023-refinery`

## What

`GtElixir.Workflows.Refinery` — per-workspace GenServer acting as a merge
queue. Picks up `{:polecat_done, bead_id}` PubSub events (and accepts
synchronous `enqueue/2` for tests), opens PRs via `GitHub.pr_open/6`,
monitors review + CI state via periodic `:tick`, and merges with the
workspace's configured strategy. Bead transitions to `:closed` on
successful merge.

## Files

- `apps/gt_elixir/lib/gt_elixir/workflows/refinery.ex` — the GenServer
  (~500 LOC).
- `apps/gt_elixir/test/gt_elixir/workflows/refinery_test.exs` — 16 tests
  covering enqueue (per-strategy), CI/review polling, merge attempt,
  failure handling, mergeable=false guard, and PubSub subscription.

## State-machine shape

```
:opening → :awaiting_approval → :ci_running → :ready_to_merge → :merging → :done
                              ↘ (mergeable=false freezes everything)
                                                                 ↘ :failed
```

`:done` triggers `Ash.update(bead, :close)` and the item is removed from
the queue.

## Reviewer items

### 1. `mergeable=false` is the top-priority guard

```elixir
cond do
  mergeable == false ->
    {item, state}    # freeze; reviewer/human resolves

  item.status == :awaiting_approval and review == "APPROVED" and merge_state == "clean" ->
    try_merge(...)
  ...
end
```

A non-mergeable PR never advances state, even when the review is APPROVED.
This was the bug the agent left mid-task — the `mergeable == false` clause
was at the bottom of the cond and never fired. The fix was reordering.
Test "mergeable=false → stays in current state and does not call merge"
exercises this.

### 2. `merge_strategy="direct"` does NOT call any PR APIs

Direct strategy is the personal-project escape hatch: no PR is opened, the
bead is moved straight to `:done`. Verified by a test that fails the
`Req.Test` stub on any HTTP — the test passes, proving no HTTP was
attempted.

`merge_strategy=pr` is the Verus-friendly default — never calls
`Worktree.push/2`; the polecat is responsible for pushing the branch
before signaling done.

### 3. PubSub topic: `"polecat:done"` (global)

The Refinery subscribes to a workspace-agnostic `"polecat:done"` topic. The
event payload is `{:polecat_done, bead_id}`; the Refinery loads the bead
to find its workspace, then ignores events whose workspace doesn't match
its own. Per-workspace topics (`"polecat:#{ws_id}:done"`) were considered
but rejected — keeping the topic flat means polecats don't need to know
which workspace they're in to emit, and the per-process workspace check
on the receiving side is a cheap Map.get on `state.workspace_id`.

### 4. Not in Application.children

Refinery instances are started per-workspace on demand (e.g. by a
future `GtElixir.Workflows.RefinerySupervisor` keyed on workspace id).
Adding to Application.children unconditionally would require knowing all
workspaces at boot, which we don't. Documented in the moduledoc.

## Test results

```
16 tests, 0 failures (workflows/refinery_test.exs)
```

`mix compile --warnings-as-errors` clean.

## Follow-ups (not in this PR)

- A `RefinerySupervisor` that starts/stops Refinery instances based on
  Workspace.config — Phase 4.
- Backoff on `pr_merge` 422 (mergeable but stale) — currently flips to
  `:failed`; could retry after a fresh `pr_get`.
- Metrics: queue depth, time-in-queue, merge success rate. Phase 5.

## Author note

The implementing agent hit an API 529 mid-task. The implementation and
tests were largely complete (16 tests, 1 failing) — the failing test
flagged a real bug in the mergeable=false guard ordering. Fixed and
committed manually; this BUILD-SUMMARY was written post-hoc.
