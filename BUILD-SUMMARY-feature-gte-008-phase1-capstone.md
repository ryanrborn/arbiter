# gte-008 — Phase 1 integration tests + dogfood switchover

Task: gte-008
Branch: `feature/gte-008-phase1-capstone`

## What

Three things:

1. **Integration smoke test** exercising the Phase 1 surface end-to-end at the
   Ash domain level (`apps/arbiter/test/integration/phase1_smoke_test.exs`,
   4 tests).
2. **Status-sync mode** on the import task (`--sync-status` flag) so existing
   rows can be refreshed from Dolt without losing local-only fields. Used for
   the switchover to bring closed-state up to date.
3. **Dogfood switchover** to arb for arbiter port tracking. Decision-doc
   updated with the switchover note + verification recipe.

## Files

- `apps/arbiter/test/integration/phase1_smoke_test.exs` — new test module:
  - ready/0 transitions across a blocking dep (open → blocked → unblocked → closed)
  - informational dep types do NOT gate readiness
  - system_managed convoy auto-closes when its sole member closes
  - owned convoy does NOT auto-close on member closure
- `apps/arbiter/lib/mix/tasks/arbiter.import_from_dolt.ex` — added
  `--sync-status` flag and `sync_issue_statuses/1`. UPDATEs `status`,
  `closed_at`, `updated_at` for rows whose Dolt-side status diverges. Does NOT
  touch title/description/etc. so local edits via arb are preserved.
- `docs/decision-doc.md` — switchover note at the top, with verification
  commands.

## End-to-end verification

```
$ mix test apps/arbiter/test/integration/
4 tests, 0 failures

$ mix arbiter.import_from_dolt --hq-path /home/rborn/dev/gt/.dolt-data/hq --sync-status
  read 118 issue rows
  workspace hq (prefix=hq): 019e41db-1b93-70e1-b1fa-dbd2c2438515
  ✓ inserted 0 new issues (118 already present)
  ✓ synced status for 2 existing issues
  ✓ inserted 0 new dependencies (66 already present)

$ mix phx.server &
$ ARB_WORKSPACE=hq apps/arbiter_cli/arb doctor
[ ok ] phoenix reachable             http://127.0.0.1:4000
[ ok ] at least one workspace exists 3 workspace(s)
[ ok ] active workspace resolves     hq (019e41db-...)

$ apps/arbiter_cli/arb list --json | jq '[.data[]|select(.id|startswith("gte-"))]|length'
33

$ apps/arbiter_cli/arb ready --json | jq '.data | length'
68
```

The `arb ready` path is the regression surface for the UUIDv7 fix
(commit b193ea9). Previously this returned a 500. Now it returns 68 ready
tasks, sourced from the live import.

The arb create + show + close round-trip was already verified in the gte-006
BUILD-SUMMARY; re-verified here against the post-import data.

## Things the reviewer should pay attention to

### 1. The `--sync-status` flag

A surgical UPDATE rather than `ON CONFLICT DO UPDATE`. Reason: an ON-CONFLICT
upsert would clobber title/notes/etc. with the Dolt values, even if those
fields have been edited locally via arb. The flag only touches `status`,
`closed_at`, and `updated_at` — the fields that change when a task transitions
state and that we WANT to track from the source of truth. If we later want a
"full sync" mode that overwrites everything, it's a separate flag.

`sync_issue_statuses/1` uses a per-row UPDATE with a WHERE-changed predicate,
not a bulk UPDATE. At ~120 rows the overhead is negligible (sub-second). If we
push more rigs through, switch to a single CTE-based bulk update.

### 2. Acceptance amended: workspace + id LIKE filter, not labels

The task's original acceptance criterion was:
> `arb list --labels arbiter-port` returns all 32 gte- tasks

The Issue resource has no `labels` field (the arb CLI currently warns and
ignores `--labels`, per gte-006 design). For switchover verification I used:

```
arb list --json | jq '[.data[] | select(.id|startswith("gte-"))] | length'
```

This returns **33**, not 32 — gte-P1 was created during Phase 1 build
(workspace+config task) and bumped the count by one. The original 33 in the
decision-doc accounts for this; the task's "32" was a stale typo.

If we want a tag/label surface later, it's a follow-up task (filed as a
to-be-named "labels on Issue" follow-up — not in this PR).

### 3. Switchover scope

The decision-doc note is explicit: **only arbiter port tracking** moves to
arb. The GT mayor's runtime in `~/dev/gt` still uses bd for everything else.
This keeps the blast radius small — if arb has a critical bug found in the
next few days, the GT-mayor's other work is unaffected.

### 4. Convoy test uses workspace_id

Caught a small gotcha in the integration test: Convoy.create requires
`workspace_id` (`allow_nil? false` on the belongs_to). The test now passes it
explicitly. If we want convoys to live "across" workspaces in the future this
will need rethinking — for now, scoped per-workspace is fine.

## Test results

```
arbiter          106 tests, 0 failures (102 prior + 4 new integration)
arbiter_web       36 tests, 0 failures (unchanged)
arbiter_cli       48 tests, 0 failures (unchanged)
total              190 tests, 0 failures
```

`mix compile --warnings-as-errors` clean.
`mix format --check-formatted` clean.

## Follow-ups (not in this PR)

- hq-109 (already filed): regression test for v4-vs-v7 Dependency UUIDs.
- Add `labels` field to Issue + arb `--labels` support (the spec hinted at it).
- Full status reconciliation tool (vs the current "status-only sync") for the
  Phase 4 broader bd-to-arb migration.
- The Dolt source-of-truth situation: my session-level `dolt sql -q UPDATE`
  commands didn't persist between invocations (working tree was clean on next
  invocation). I worked around it by closing via arb instead, but the GT-side
  Dolt is fragile in a way worth filing against the broader system.
