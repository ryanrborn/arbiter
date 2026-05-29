# Review: feature/bd-958jdg-polecat-awaiting-review-lifecycle-step-app

**Bead:** bd-958jdg (reviewed under bd-abw7hd)
**Builder:** polecat (PR #14, commits 247cede + fcc7e4c)
**Reviewer:** polecat (bd-abw7hd)
**Date:** 2026-05-28

## Verdict

**APPROVE — with one required fix (test isolation).**

The production implementation is correct, complete, and well-documented:
every one of the six verification points in the directive is met, and the
40 new tests pass in isolation. The one thing to address before merge is a
**verified test-isolation regression** — the new `async: false` Polecat suites
intermittently destabilize the full test run, turning a stable 14-failure
baseline into an occasional 15. It is test-only (no production-logic defect),
but it erodes the very "14 pre-existing, unchanged" contract the PR rests on.

## Diff summary

Wires the `Arbiter.Mergers` abstraction (bd-1qx1nt / bd-9bn4n9) into the
polecat lifecycle so an acolyte can open a merge request and **park at
`:awaiting_review`** instead of completing the moment work finishes.

- **`Arbiter.Polecat`** gains `:awaiting_review`
  (`idle → running → awaiting_review → completed | failed`). `open_mr/5`
  resolves the workspace merger adapter, calls `open/4`, stores
  `mr_ref` + clickable `merger_url`, transitions `:running → :awaiting_review`,
  and spawns a `Warden`. `complete/2`/`fail/2` accept `:awaiting_review`;
  a late `gt done` is **ignored** while parked. `record_merger_status/2`
  mirrors the latest `get/1` result + `last_checked_at` onto meta.
- **`Arbiter.Polecat.Warden`** (new) — one supervised watchdog per parked
  polecat under a new `WardenSupervisor`, polling `Mergers.get/1` every N ms
  (default 60s). `classify/1` is the single approval-detection function
  (`merged | approved | closed | pending`). Monitors the polecat and stops on
  `:DOWN`; self-stops on terminal transitions.
- **`Arbiter.Mergers.prepare/1`** seeds per-process adapter config (GitLab),
  keeping adapter coupling out of the Warden/Polecat.
- **`Workspace.auto_merge?/1`** reads `config[merge][auto_merge]` (default
  `false`, bool + JSON-string).
- **UI/API** — dashboard badge-warning + linked MR ref; detail-view "Merge
  request" card (link, approval, poll interval, last-checked); `mr_ref`/
  `merger_url`/`last_merger_status`/`last_checked_at` on the JSON endpoints.
- Incidentally restores `workspace.ex`'s Ash DSL to the canonical paren-free
  `Spark.Formatter` style (the stacked base branch had drifted) — same benign
  reformatting the bd-6c6w82 review already noted.

## Acceptance criteria check

- [x] **State machine transition is clean** — FSM is documented and guarded.
  `open_mr` is valid only from `:running` (polecat.ex `handle_call`); a second
  clause returns `{:error, {:invalid_transition, status, :awaiting_review}}`
  for any other status. `complete/2` and `fail/2` widen their guards to include
  `:awaiting_review`. Illegal transitions are rejected, not silently dropped.
  Tested: transition + store, rejection from `:idle`, adapter-error leaves the
  polecat `:running`.
- [x] **Warden is supervised and shuts down when the machine exits
  `:awaiting_review`** — started under `Arbiter.Polecat.WardenSupervisor`
  (`DynamicSupervisor`, `restart: :temporary`); `init/1` calls
  `Process.monitor(polecat_pid)` and returns `:ignore` if the polecat is
  already gone. On `merged`/`closed`/auto-merged it drives the terminal
  transition then `{:stop, :normal}`; on the polecat's `:DOWN` it stops.
  Tested: merged→complete+stop, closed→fail+stop, polecat-death→stop,
  init→`:ignore`. (One theoretical gap — see Suggested #3.)
- [x] **auto_merge config is respected** — `Workspace.auto_merge?/1` defaults
  `false`, accepts bool `true` and JSON string `"true"`; `apply_outcome(:approved,
  …, %{auto_merge: true})` calls `Mergers.merge/1` then completes, while
  `auto_merge: false` parks until a later poll sees `:merged`. Tested both
  paths (incl. `merge_count == 0` for the manual path) and the `auto_merge?/1`
  matrix.
- [x] **mr_ref is persisted on the Machine** — stored on the in-memory
  `%State{}` (`mr_ref`, `merger_url`, internal `merger_adapter`), mirrored into
  `meta`, and exposed via `snapshot/1` + both JSON endpoints. Satisfies the
  directive's "on the Machine state / metadata." (Durability across a node
  restart is out of scope — see Suggested #2.)
- [x] **UI shows badge-warning and MR link** — `:awaiting_review` →
  `badge-warning` in both `dashboard_live` and `polecat_detail_live`; dashboard
  links the MR ref to `merger_url` (falls back to a `<code>` ref when no URL);
  the detail "Merge request" card shows the link, approval badge, poll
  interval, and last-checked timestamp, and `:awaiting_review` is stoppable.
- [x] **Webhook upgrade path is documented** — the `Warden` moduledoc has a
  dedicated "Webhook upgrade (design only — not implemented here)" section
  describing `POST /webhooks/{gitlab,github}` reusing `classify/1` verbatim,
  with polling demoted to a backstop. `classify/1` is genuinely the single
  decision surface, so the swap is real, not aspirational.

## Verification performed

Built the PR branch in a clean worktree (`MIX_ENV=test mix compile` — 0
warnings of consequence) against the live Postgres.

- **New suites in isolation:** `warden_test.exs`, `polecat_awaiting_review_test.exs`,
  `workspace_test.exs` → **40 tests, 0 failures.** Confirms the builder's claim.
- **Full `arbiter` suite, base branch (bd-9bn4n9):** 6 runs → **14 failures
  every time, zero variance.** Confirms the "14 pre-existing in arbiter" claim
  and establishes a stable baseline.
- **Full `arbiter` suite, PR branch:** ~18 runs → **mostly 14, but two runs hit
  15.** The extra failure floated between the *new* `PolecatAwaitingReviewTest`
  ("transitions :running -> :awaiting_review") once, and the *pre-existing*
  `Polecat.DriverTest` ("machine dies mid-run…") once. The latter failed with
  `{:exit, {:noproc, {:gen_statem, :call, [pid, :advance, :infinity]}}}` — a
  race against the singleton Polecat infrastructure that the base never
  exhibits. See Required, below.

The 14 baseline failures are the known merger-campaign collision (`merge.strategy`
validation vs the legacy Refinery `squash`/`pr`/`rebase` values) plus the
`tracker_types/0` vernacular rename — pre-existing and out of scope, exactly as
the PR states.

## Findings

### Required (address before merge)

- **The new `async: false` Polecat suites are not isolated from the singleton
  Polecat infrastructure, making the full suite intermittently flaky.** Base
  branch: 14 failures across 6 runs, no variance. PR branch: 14 *or* 15 across
  ~18 runs — the 15th being either the new `PolecatAwaitingReviewTest` or the
  previously-stable `Polecat.DriverTest`. Both new suites start `Polecat` and
  `Warden` processes under the global `Arbiter.Polecat.Registry` /
  `Polecat.Supervisor` / new `WardenSupervisor`; Wardens poll every 20ms and
  the spawned processes aren't in the DB sandbox (hence the flood of
  `record_run_create/1 swallowed … DBConnection.OwnershipError` warnings).
  Leftover/short-lived Wardens and Polecats racing the shared registry against
  `DriverTest` is the most likely culprit. It is test-only — the production
  lifecycle code is correct — but a ~10% intermittent full-suite failure
  undercuts the PR's own "14 unchanged" contract and will redden CI at random.
  Suggested fixes: ensure every test deterministically tears down its Warden(s)
  *and* the auto-started Warden from `open_mr` (capture/await its stop, or stop
  the `WardenSupervisor` children in `on_exit`); allow the spawned processes on
  the sandbox connection (`Ecto.Adapters.SQL.Sandbox.allow/3`) or run shared
  mode to remove the un-owned DB writes; and consider asserting Warden teardown
  rather than relying on a 20ms cadence.

### Suggested (nice to have — file follow-up beads, do not block)

- **Poll interval is not configurable via workspace config.** The directive
  says "every N seconds (configurable, default 60s)." It *is* overridable via
  `open_mr` opts (`:interval_ms`), but nothing reads `config[merge][...]` for
  it the way `auto_merge?` does, and `polecat_detail_live` hardcodes
  `Warden.default_interval_ms()` — so any non-default interval would be
  misreported in the UI. Add a `Workspace.poll_interval_ms/1` (mirroring
  `auto_merge?/1`), thread it through `start_warden`, and render the Warden's
  actual interval.
- **No crash/restart recovery for parked polecats.** The `Warden` is
  `restart: :temporary` and the `Polecat` is an in-memory GenServer, so a node
  restart loses both — an open MR is then orphaned with no poller. This matches
  the "polling now, webhook later" scope, but a follow-up to re-spawn Wardens
  for `:awaiting_review` polecats on boot (or persist `mr_ref` to the `Run` row)
  would close the durability gap. Note `:transient` would survive a *Warden*
  crash but not a node restart, since the state dies with the Polecat.
- **Warden doesn't re-verify the polecat is still `:awaiting_review` before
  acting.** Today the only non-Warden exit from `:awaiting_review` is the UI
  stop, which kills the process (→ `:DOWN` → Warden stops), so this is
  theoretical. But if any future path completes/fails a still-alive parked
  polecat, the Warden would keep polling until its own `get/1` happens to see a
  terminal state. A cheap guard (skip the outcome if the polecat is no longer
  `:awaiting_review`) future-proofs it.
- **auto-merge retry is unbounded.** A persistently failing `Mergers.merge/1`
  reschedules every interval forever. Staying parked is the safe default, but a
  bounded retry that surfaces the error to the UI (or fails the bead after N
  attempts) would avoid a silent spin.
- **Doc nits.** The `Warden` moduledoc references `apply_outcome/2`; the
  function is `apply_outcome/3`. The catch-all `:__claude_session_done__`
  comment (polecat.ex:701) still says "Already :completed or :failed" though it
  now also (correctly) catches `:awaiting_review`.

## Notes

Code quality is high: the `safe_*` wrappers around adapter calls are
appropriately defensive, `classify/1` as the lone decision surface is exactly
the right shape for the documented webhook swap, and `Mergers.prepare/1`
cleanly keeps the GitLab process-dict coupling out of the generic Warden. The
`StubMerger` being a named `Agent` (not a process-dict stub) is the correct
call given the Warden polls from its own process — the irony is that this same
cross-process design is what the Required isolation finding is about.
