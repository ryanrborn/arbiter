# gt-elixir cutover post-mortem

**Status:** Draft (skeleton — Ryan to flesh out from memory)
**Cutover date:** 2026-05-20
**Author:** Mayor

## Total elapsed time

- **Phase 0 decision doc landed:** 2026-05-18 (commit `a244a58`)
- **First feature commit (gte-001 umbrella scaffold):** 2026-05-19 19:21 UTC
- **Cutover executed:** 2026-05-20
- **Elapsed:** ~2 calendar days from Phase 0 to cutover.

Phase 0 estimate was **28-42 days of focused work**, or **6-8 calendar
weeks** at the assumed cadence (3-4 hours/day Ryan direction, 2-3 polecat
PRs/day). Actual was roughly an order of magnitude faster — the assumed
cadence was wildly low for an AI-driven port where most tasks were one or
two Claude sessions of focused work, not human-day units.

## Tasks completed vs Phase 0 estimate

**Scoped:** 33 tasks (gte-001..028, gte-P1..P4, gte-029).

**Status snapshot at cutover (from Postgres after final `--sync-status` import):**

- Closed (per Dolt source): gte-001, gte-002, gte-003, gte-006, gte-007, gte-P1.
- Open: everything else.

**Caveat — the status snapshot lies.** Git history shows feature commits
landed for many tasks that still read `open` in Dolt/Postgres
(gte-016, gte-017, gte-021..025, gte-P4, etc.). Task status in Dolt
drifted out of sync with reality during the late-Phase implementation
push because the Mayor stopped closing tasks in Dolt once dogfood
switchover happened at gte-008 (per decision-doc § "Dogfood switchover").
**TODO (Ryan):** decide whether to backfill status via bd2 now or treat
this as historic noise.

## Bugs surfaced during parallel run

**TODO (Ryan):** the cutover plan called for "at least 3 days of parallel
run (gte-027 closed)" but elapsed-time data shows < 2 days between
Phase 0 and cutover, so the parallel-run window was abbreviated.

Things to recall and write up:
- Any bd / bd2 disagreement during dogfood?
- Any importer bugs found after first run of `mix gt_elixir.import_from_dolt`?
- Any LiveView / PRPatrol / Refinery merge-queue issues observed live?

## What was harder than expected

**TODO (Ryan).** Candidates worth considering:
- Was the persona/vernacular system more invasive than expected
  (gte-P1..P4 spans the whole stack)?
- Did Ash's data-layer choice (switching SQLite → Postgres on day 1)
  cost time, or was Igniter's regeneration fast enough?
- Anything in the GT surface that Phase 0 missed entirely?

## What was easier than expected

**TODO (Ryan).** Candidates:
- The 6 ported formulas (Phase 3) seem to have landed in a handful of
  tasks (gte-016, gte-017, gte-021, gte-022, gte-023) within ~hours of
  each other on 2026-05-20 — Workflows abstraction paid off?
- Postgres + Ash vs the Phase 0 SQLite assumption — was the switch as
  cheap as decision #1 predicted?
- Dolt → Postgres importer (gte-007) — 150 rows imported clean, no
  data-shape changes required at cutover (per cutover plan §
  "What's NOT in this plan").

## What the Phase 0 decision doc got wrong

1. **Time estimate.** 28-42 focused days / 6-8 calendar weeks was off by
   roughly an order of magnitude. Root cause: assumed cadence figures
   (3-4 hours/day of Ryan direction, 2-3 polecat PRs/day) modeled a
   human-paced workflow, not an AI-driven port where most tasks close in
   a single Claude session. Future estimates for AI-driven ports should
   start from "tasks × ~1-2 sessions/task" rather than human-day units.

2. **Parallel-run duration.** Phase 0 risk-table promised "Dual-run for
   3-5 days before decommissioning" as the migration data-loss
   mitigation. Actual parallel run was abbreviated. The compensating
   control was the `.dolt-data/` archive (90-day retention) — fine for
   single-user, but the risk-table should reflect that the archive
   *was* the mitigation, not the dual-run.

3. **Task status discipline.** Phase 0 didn't predict that the
   dogfood-switchover (decision-doc § 2026-05-19) would cause task
   statuses in Dolt to stop being updated. Anyone re-reading the
   `import_from_dolt --sync-status` output will see a misleading
   open/closed picture. **TODO (Ryan):** consider whether a future
   migration should fully cut the legacy tracker before implementation
   starts, rather than running dogfood-on-the-build-it.

4. **TODO (Ryan):** anything else from the build that surprised you?

## Open follow-ups

- Decide whether to backfill task statuses (see "Tasks completed" caveat).
- gte-028 (Decommission GT) closure — should fire once the 7-day rollback
  window expires (≈ 2026-05-27).
- The old `gt` Go binary at `~/.local/bin/gt` is still on PATH; cutover
  plan didn't address it. Leave for the rollback window, then remove.
