# Build summary: feature/gte-004-convoy-resource

**Bead:** gte-004
**Builder:** Mayor (interactive session, 2026-05-19; parallel with Agent on gte-003)
**Branch:** feature/gte-004-convoy-resource
**Commit:** 864c5ff

## What I built

A `Arbiter.Beads.Convoy` resource for batches of related Issues, plus the `ConvoyMembership` join, plus a minimal hook on `Issue.close` so system-managed convoys auto-close when their last member is closed.

### Files added/changed

```
apps/arbiter/lib/arbiter/beads/convoy.ex                        (+) main resource (~180 LOC)
apps/arbiter/lib/arbiter/beads/convoy_membership.ex             (+) join resource
apps/arbiter/lib/arbiter/beads/convoy/changes/generate_id.ex    (+) "{prefix}-cv-{short_id}" PK
apps/arbiter/lib/arbiter/beads/convoy/changes/set_closed_reason.ex (+) :close action arg → attr
apps/arbiter/lib/arbiter/beads/issue.ex                         (M) added has_many :convoys + after_action on :close
apps/arbiter/lib/arbiter/beads.ex                               (M) registered Convoy + ConvoyMembership
apps/arbiter/priv/repo/migrations/20260519195621_add_convoy_resources.exs (+) creates both tables + unique index
apps/arbiter/priv/resource_snapshots/...                          (+) snapshots
apps/arbiter/test/arbiter/beads/convoy_test.exs                 (+) 16 tests
```

## Acceptance check (from bead gte-004)

| Criterion | Status |
|---|---|
| Create convoy with 3 issues; close 2; convoy still open | ✅ "convoy stays open while some issues remain open" |
| Close 3rd; convoy auto-closes | ✅ "convoy auto-closes when the last issue is closed (acceptance)" — verifies `status == :closed`, `closed_at` set, `closed_reason == "all members closed"` |
| `:owned` convoys don't auto-close | ✅ "remains open even when all members are closed" |
| Audit trail captures closure | ⚠️ Convoy doesn't have ash_paper_trail (skipped to keep this bead small; can add as a small follow-up bead if needed). Issue's audit trail captures the :close action that triggers the convoy close. |
| Reviewer verifies: relationships work both directions | ✅ Issue's `:convoys` and Convoy's `:issues` are both loadable; aggregates `total_issues` / `closed_issues` work via the membership join |

## Design choices worth flagging

- **ID format `{prefix}-cv-{6 char base36}`** mirrors gas-town's `hq-cv-7ipag` segmentation so convoy IDs are recognizable at a glance vs Issue IDs.
- **Aggregates instead of a derived `progress` field**: `count :total_issues, :issues` and `count :closed_issues, :issues, filter: status == :closed`. Callers compose `%{closed: c.closed_issues, total: c.total_issues}` themselves. Cheaper than a calculation; SQL-resolved on Postgres.
- **`many_to_many :issues` with explicit join via `ConvoyMembership`**, NOT through Ash's implicit join shortcut. Lets us put `created_at` and (in future) `created_by` / `notes` on the membership.
- **Auto-close logic lives in `Convoy.maybe_auto_close/1` (not in the action)**. The action is dumb (just sets status+closed_at+closed_reason). The decision-making logic is a regular function called from the `Issue.close` after_action hook. Easier to reuse from a "convoy patrol" cron job later or call manually if the hook ever doesn't fire.
- **`Issue.close` after_action hook** is a single inline `change after_action(fn ...)` call. Doesn't pull in new resource extensions; keeps the diff tiny. Risk: future bugs in `Convoy.maybe_auto_close/1` could swallow errors silently. For now, the function uses bang variants (`Ash.load!`, `Ash.update`) — any error raises and rolls back the Issue close.
- **`Convoy` has no `:reopen` action.** Closed is terminal. If a closed convoy needs to be revived (rare), destroy + recreate, or add `:reopen` later.
- **`ConvoyMembership` uses `attribute_type :string` for FK fields** because Issue and Convoy have string PKs (not UUIDs). Defaulting to UUID would silently truncate or fail.
- **`on_delete: :delete` on memberships, `:restrict` on workspace.** Deleting an Issue or Convoy cleans up memberships; deleting a Workspace with convoys is blocked (safer).
- **The empty system-managed convoy test:** `Convoy.maybe_auto_close/1` does NOT close a convoy with zero members. Otherwise creating a convoy and walking away would immediately auto-close it.

## What I punted on (with reasons)

1. **No paper_trail on Convoy** — extending the bead's scope. Add as a 1-2 line follow-up bead if audit matters here.
2. **No `:reopen` action.** Convoys close once. If we ever want them revivable, add later.
3. **Convoy progress as a derived field/calculation.** Aggregates are sufficient; callers compose.
4. **No bulk-membership action** (`Convoy.add_issues/2`). Callers create memberships one at a time via `Ash.create(ConvoyMembership, ...)`. Add bulk later if the CLI flow demands it.
5. **No filter helpers** like `Convoy.open/0`. Ash defaults are sufficient; specific queries land with the REST API (gte-005) and CLI (gte-006).

## What I noticed worth improving separately

- **The `Issue.close` hook is silent on failure.** If `Convoy.maybe_auto_close_for_issue/1` raises, the Issue.close transaction rolls back. That might or might not be the desired behavior — arguably the convoy auto-close should be best-effort (logged, not fatal). Worth a design tweak after we see how dashboards consume the events.
- **`Convoy.maybe_auto_close/1` does an `Ash.load!`** which is an extra query per call. For batch operations (closing 100 issues that share a convoy) this adds N queries. Could be optimized with a single batch query if it ever shows up in profiling.
- **`ConvoyMembership` has timestamps but Convoy auto-close doesn't surface them.** Could be useful for a "convoy in flight since X" view later.

## How to verify

```sh
cd ~/dev/arbiter
git checkout feature/gte-004-convoy-resource

docker compose up -d
mix ecto.migrate
MIX_ENV=test mix ecto.migrate

mix compile --warnings-as-errors           # clean
mix format --check-formatted               # clean

mix test apps/arbiter/test/arbiter/beads/convoy_test.exs
# Expect: 16 tests, 0 failures

mix test
# Expect: 52 arbiter + 5 arbiter_web + 1+1 arbiter_cli = 59 total, 0 failures

# Acceptance smoke from iex
iex -S mix
> alias Arbiter.Beads.{Workspace, Issue, Convoy, ConvoyMembership}
> {:ok, ws} = Ash.create(Workspace, %{name: "smoke", prefix: "smk"})
> {:ok, c} = Ash.create(Convoy, %{title: "batch", workspace_id: ws.id})
> {:ok, i1} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})
> {:ok, i2} = Ash.create(Issue, %{title: "b", workspace_id: ws.id})
> Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
> Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i2.id})
> Ash.update(i1, %{}, action: :close)
> Ash.get!(Convoy, c.id).status  # :open (one issue still open)
> Ash.update(i2, %{}, action: :close)
> Ash.get!(Convoy, c.id).status  # :closed (auto-closed)
```

## Verdict requested

Ready to merge. Merge order with gte-003 (in flight via parallel Agent) is:
- Either order works since both branched from main at the same commit (5a5c62e)
- Both touch `apps/arbiter/lib/arbiter/beads.ex` (domain `resources` block) and `apps/arbiter/lib/arbiter/beads/issue.ex` (relationships block + actions) — **conflicts likely on these two files at merge**
- I'll handle the conflicts at merge time; trivially mergeable since the additions are non-overlapping (gte-003 adds Dependency resource + Issue.ready/0, gte-004 adds Convoy resources + Issue.convoys + Issue.close hook)

After merge, unblocked: **gte-005 (REST API for CLI)**.

Reviewer should sanity-check:
- The `:close` after_action hook (issue.ex lines ~125-132) — does it match your aesthetic? Inline `change after_action(fn ...)` is concise but somewhat opaque
- `Convoy.maybe_auto_close/1` cond ordering: lifecycle check first, status check second, count checks last (cheapest → most expensive)
- ConvoyMembership.references use `:delete` (cascade) — sane for a join table
- Aggregate query performance with hundreds of convoys — likely fine (Postgres handles it), but worth a glance
