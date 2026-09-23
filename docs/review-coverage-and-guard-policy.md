# Review coverage, and one failure policy for every review/merge guard

**Status:** design proposal (the design deliverable for #1631; not yet approved,
no implementation — this PR changes nothing under `apps/*/lib`)
**Date:** 2026-09-13
**Task:** bd-6woz0x · **Tracker:** github:1631
**Author:** worker
**Adopted from:** recommendation 2 of the follow-up-rate investigation
(bd-bc0n3k, `admiral:notes/2026-09-13-follow-up-rate-investigation.md` §3.3–3.4,
§5 — the operator's notes repo, not this one),
adopted by the operator 2026-09-13.
**Freeze:** until this design merges, new review/merge-guard bugs route here
rather than to one-off fixes, unless one is actively stranding work.

## TL;DR

Two changes, one enforcement mechanism.

1. **Replace the single stamped `last_reviewed_sha` with a review-coverage
   set.** "The reviewed SHA" is not one value. A `REQUEST_CHANGES → fix →
   APPROVE` cycle produces several commits with different review status, and a
   post-approval CI `fix_pass` adds another. Every guard in chain A is the same
   latent modelling error — one string where a set belongs — patched three
   times without being fixed. The replacement is an append-only
   `review_coverage` table plus **one three-valued predicate**:
   `covered | uncovered | unknown`. The third value is the whole point: today
   "the branch advanced past the review" and "the forge has not caught up with
   the review's own push" are the same `{:error, {:stale_reviewed_sha, …}}`,
   and #1622 is the bill for that. Content equality comes from
   `Arbiter.Mergers.NetDiff` — which already exists and already computes a
   `git patch-id --stable`-style fingerprint — so a merge from the base, a
   rebase-forward, and a force-push of identical content are all *covered*,
   while a conflict resolution that writes content is not.

2. **One failure policy, declared per guard class.** Every guard is exactly one
   of six classes; each class states fail-open-with-escalation or
   fail-closed-with-escalation, and an attempt bound N. Two invariants bind all
   of them: **nothing retries indefinitely**, and **no guard converts "blocked
   by the guard" into a failed run on an approved PR.** Today the merge guard
   retried one PR 303+ times, the MergeQueue's stale-SHA path has *no bound at
   all* (`apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1763` (`try_merge`)
   deliberately leaves `status` untouched so it re-attempts every tick forever),
   and `$325.82 across 73 runs` was charged to runs that failed for gate reasons
   and produced nothing.

3. **The enforcement mechanism is a guard registry.** Every guard declares its
   class, bound and escalation-episode key in one list, and a test fails if a
   refusal path exists without a row. That is what actually ends the
   guard-begets-guard loop — the freeze is a policy, the registry is a
   compile-and-test-time obligation.

The model must still block genuinely unreviewed post-approval commits (cause A,
the original #1498 incident). §4.5 walks that case through and it stays blocked.

---

## 1. What is actually going wrong

The review/merge control plane is patching itself in a loop. Each guard was
correct in isolation; each one's failure mode was "correct work is now blocked",
and each was found within a day by production traffic.

**Chain A — the merge guard, 4 links in 9 days, both repos.**

| # | Task | PR | What it added | How it failed |
|---|---|---|---|---|
| 1 | bd-dxgris | #1498 | Stamp a reviewed SHA; refuse to merge any other head | (the original hole: `safe_merge/1` passed no expected SHA) |
| 2 | bd-6bg54c | #1585 | Re-read the stamp; `NetDiff` for base merges | Within 9h, **five approved PRs** stalled on `{:stale_reviewed_sha, …}`; one retried **303+** times; the operator hand-merged all five |
| 3 | bd-ch9pmk | #1622 | Wait for the forge to echo our own pushed head | An APPROVED fix round failed with `{:unreviewed_head, <pre-fix-round sha>}`; every `REQUEST_CHANGES → fix → APPROVE` cycle bought a redundant full re-review |
| 4 | bd-2eyf9y | #1594 | A commit gate on fix rounds | Added because a fix round would otherwise re-review an unchanged diff |

**Chain B — the ReviewGate verdict parser, 4–5 links in 5 days.**
bd-6dxit2 (INCONCLUSIVE on reviews that *did* produce a verdict) → bd-869mmg
(#1613: parser missed gemini output; a textbook `VERDICT: REQUEST_CHANGES`
emitted twice, run failed `:review_gate_inconclusive`) → bd-1xss5z (#1617: agy's
5-minute print timeout truncated the review, recorded as "gemini session
SUCCESS") → bd-c6tdbu (#1630: an honest APPROVE rejected because a round-1
section headed "Non-blocking observations (no change requested)" parsed into
fail-closed Medium findings) → bd-3hb4ih, still open.

**Scale.** `worker/watchdog.ex` 1,550 → 3,130 lines in 31 days (+102%).
`worker/review_gate.ex` 2,957 → 3,799, with 43% of its lifetime commits landing
this month. The seven control-plane files grew 11,155 → 14,768 lines (+32.4%)
and took 39% of all the commits they have ever received, in 31 days.

**Cost.** `$325.82 across 73 runs` bought nothing: `:review_gate_inconclusive`
(52 runs, $226.97), `{:awaiting_review_timeout, 30}` (12 runs, $43.27),
`{:unreviewed_head, …}`, `review_not_started`. That is 9.0% of the month's
entire agent spend spent on the gate misfiring.

### 1.1 The two root causes, stated precisely

**RC1 — "the reviewed SHA" is a single value.** `issues.last_reviewed_sha`
(`apps/arbiter/lib/arbiter/tasks/issue.ex:909` (`last_reviewed_sha`)) is one
nullable string, written by whichever of four unrelated writers ran last. There
is no record of *which* commits an approval covered, so every consumer
reconstructs one — badly, and differently. `Arbiter.Mergers.ReviewedSha` invents
a *latch* (`apps/arbiter/lib/arbiter/mergers/reviewed_sha.ex:67` (`latch`)),
both the Watchdog and the MergeQueue then invent a *suspension* on top of the
latch (`apps/arbiter/lib/arbiter/worker/watchdog.ex:3916` (`clear_reviewed_latch`), `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1701` (`clear_reviewed_latch`)), and the Watchdog invents a *memo invalidation* on top
of the suspension (`apps/arbiter/lib/arbiter/worker/watchdog.ex:3801` (`load_recorded_reviewed_sha`)). All of that machinery is an attempt to
reconstruct a set from a scalar.

**RC2 — the comparison is two-valued.** `ReviewedSha.check/2`
(`apps/arbiter/lib/arbiter/mergers/reviewed_sha.ex:82` (`check`)) answers
`{:ok, sha} | {:error, {:stale_reviewed_sha, …}}`. But there are **three**
real answers, and the missing one is the common path:

* the head is covered → merge;
* the head carries content nobody reviewed → do not merge;
* **we cannot yet tell** — the forge's PR resource has not caught up with the
  push the review itself produced, or the diff fetch failed, or there is no base
  ref to compare against.

#1622 is exactly the third case being reported as the second. The shipped fix
bolts the missing value on *outside* the comparison, as a boolean latch with its
own grace counter (`apps/arbiter/lib/arbiter/worker/watchdog.ex:3169` (`forge_head_lagging?`), `apps/arbiter/lib/arbiter/worker/watchdog.ex:259`
(`head_lag_grace_polls`)) — which works, and is a fifth thing to keep in sync.

---

## 2. Guard inventory

Every guard, verdict guard and refusal path in the review/merge control plane.
"On failure" is what happens **when the guard misfires** — when it refuses work
that was actually fine.

Citations are anchored: `` `path:line` (`symbol`) ``. They are checked by
`apps/arbiter/test/arbiter/review_coverage_design_test.exs`, which fails the
suite if a cited symbol drifts more than ±60 lines from its line — so this
inventory cannot silently rot.

### 2.1 `apps/arbiter/lib/arbiter/worker/review_gate.ex` — the in-process gate

| # | Guard | Anchor | Protects against | Misfire mode | On failure | Patches |
|---|---|---|---|---|---|---|
| G1 | Pre-spawn commit check — branch has commits ahead of target | `apps/arbiter/lib/arbiter/worker/review_gate.ex:3563` (`reviewer_commit_check`) | bd-1mksks: reviewing an empty branch, reviewer reports "no work" | Git hiccup reads as "no commits" | **Fails open** (git errors → proceed); genuine `{:ok, false}` → `escalate_pre_review` | 2 (bd-1mksks, bd-ofql8k) |
| G2 | Empty diff-range guard (`base_sha == head_sha`) | `apps/arbiter/lib/arbiter/worker/review_gate.ex:3607` (`empty_diff_guard`) | bd-31bh37: target already absorbed the commits; bogus REQUEST_CHANGES | A legitimately-absorbed branch escalates instead of completing | Escalates via `apps/arbiter/lib/arbiter/worker/review_gate.ex:3137` (`escalate_pre_review`) — since P9, **parks** `:empty_diff`, one escalation, run recorded `review_parked` | 1 |
| G3 | Reviewing-pass timeout, with one fresh-mind retry | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1239` (`timeout_retries_left`), bound `apps/arbiter/lib/arbiter/worker/review_gate.ex:190` (`default_timeout_retries`) | bd-78vg4v: transient hung session | A slow-but-working review is killed and re-paid | Retry once, then `escalate_timeout` → since P9, **parks** `:reviewer_timeout` (was a **failed run** `:review_gate_inconclusive`) | 2 |
| G4 | Timeout → `:no_verdict`, not `:request_changes` | `apps/arbiter/lib/arbiter/worker/review_gate.ex:3171` (`escalate_timeout`) | bd-216r3e: synthetic single-finding REQUEST_CHANGES → self-sustaining re-dispatch loop | — (this one is a *fix* to a prior misfire) | Records `verdict: :timed_out`, reports `:no_verdict` | 1 |
| G5 | Verdict parse — `VERDICT:` line, memory then durable transcript | `apps/arbiter/lib/arbiter/worker/review_gate.ex:478` (`parse_verdict`), regex `apps/arbiter/lib/arbiter/worker/review_gate.ex:261` (`verdict_approve`) | bd-6dxit2: a dropped PubSub line reads as "reviewer said nothing" | A real verdict in an unrecognised shape → `:no_verdict` | `maybe_reprompt` | **Chain B: 4–5** |
| G6 | Verdict re-prompt budget | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2600` (`maybe_reprompt`), bound `apps/arbiter/lib/arbiter/worker/review_gate.ex:181` (`default_verdict_retries`) | bd-8v8ays: malformed verdict wastes a whole review | Two passes paid, still no verdict | Since P9, **parks** `:inconclusive` (was a **failed run** `:review_gate_inconclusive`) | 3 |
| G7 | Last-ditch transcript recovery before conceding | `apps/arbiter/lib/arbiter/worker/review_gate.ex:554` (`recover_verdict_from_scans`) | bd-869mmg/bd-atyrrq: a real review discarded as inconclusive | — | Re-dispatches the recovered verdict | 1 |
| G8 | Empty-findings guard on REQUEST_CHANGES | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1402` (`findings_present?`) | bd-3y2mda: revise loop entered with nothing to act on | A terse-but-real finding under 16 chars | Shares G6's budget; then, since P9, **parks** `:inconclusive` (was a **failed run**) | 2 |
| G9 | Verdict guard: partial verification | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2875` (`verdict_guard_spec`) | bd-4te55l: `VERIFICATION: PARTIAL` findings taken at face value | Honest disclosure is punished with an extra round | Re-prompt ×1, then fail-closed behind a banner; since P9 the terminal **parks** `:verdict_guard_exhausted` rather than failing the run (content stays closed — nothing merges) | 1 |
| G10 | Verdict guard: unaddressed findings | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2888` (`unaddressed_findings`) | bd-6r8caj: APPROVE that never revisits its own open finding | **bd-c6tdbu**: a non-blocking observation parsed as a Medium finding → honest APPROVE rejected, forced fix round had nothing to fix → **failed run** | Re-prompt ×1, then `fail_closed` → since P9 **parks** `:verdict_guard_exhausted` (content stays closed) | **3** |
| G11 | Verdict guard: unmet criteria | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2914` (`unmet_criteria`) | bd-4yhv4x: APPROVE with a `[NOT MET]` criterion | A criterion the reviewer mis-parsed blocks a good PR | Re-prompt ×1, then `fail_closed` → since P9 **parks** `:verdict_guard_exhausted` (content stays closed) | 1 |
| G12 | Verdict guard: missing criteria breakdown | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2938` (`missing_criteria`) | bd-4yhv4x occurrences #1/#2: bare holistic APPROVE | Reviewer omits the breakdown on a trivially-correct diff | Re-prompt ×1, then `fail_closed` → since P9 **parks** `:verdict_guard_exhausted` (content stays closed) | 1 |
| G13 | Shared guard dispatcher + terminal handling | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2791` (`run_verdict_guard`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:2823` (`fail_closed`), registry `apps/arbiter/lib/arbiter/worker/review_gate.ex:2746` (`verdict_guards`) | Four guards drifting apart | — | — | — |
| G14 | Round budget exhausted | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1584` (`do_route_after_reject`) | Unbounded review↔revise ping-pong | A converging task one round short escalates | Escalate with transcript → **failed run**. P9 left this one deliberately: a reviewer that really said REQUEST_CHANGES every round is an honest rejection, so only the verdict-guard arm that routes here now parks | 2 |
| G15 | Commit gate: HEAD unchanged after a fix round | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1805` (`commit_gate_outcome`) | bd-2eyf9y: re-reviewing an identical diff; bd-cb7wpq: a finding legitimately fixed via a non-file channel (a PR title/description edit, a label, a comment) parked as if the worker had done nothing | A legitimate rebuttal-only round is treated as failure | Nudge ×1, then `escalate_commit_gate` → since P9, **parks** `:commit_gate_no_changes` / `:commit_gate_uncommitted`; since bd-cb7wpq, an explicit `NO-FILE-CHANGE:` disposition (`non_file_fix_declared?/1`) dispatches round 2 for a real re-review instead, and only escalates (`:commit_gate_no_changes_after_non_file_fix`) if it happens twice in a row with nothing new for the reviewer to check (was a **failed run**) | 3 (bd-2eyf9y, bd-c6tdbu, bd-cb7wpq) |
| G16 | Commit-gate escalations (4 shapes) | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2081` (`escalate_commit_gate`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:1875` (`escalate_no_changes`) | bd-c6tdbu: the "no changes" message was misleading after an approval-gap reject | — | Since P9, **parks** (`:commit_gate_*` / `:no_changes_after_approval_gap` / `:commit_gate_no_changes_after_non_file_fix`); was a **failed run** `:review_gate_inconclusive` | 2 |
| G17 | Reviewed-SHA stamp on APPROVE | `apps/arbiter/lib/arbiter/worker/review_gate.ex:3678` (`stamp_reviewed_head`) | bd-6bg54c cause B: guard could never learn a later round approved a newer head | Best-effort; a failed write silently leaves the *old, conservative* value — which is precisely the #1585 stall | Logs and continues | 1 |
| G18 | Pre-review push gate — the head under review must be on `origin/<branch>` | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1001` (`push_gate`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:1033` (`escalate_unpushed_head`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:1094` (`pushed_head`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:1598` (`remote_advance`, the pre-fix-round half), `apps/arbiter/lib/arbiter/reviews/push_state.ex` (the git primitive, incl. the worktree-must-be-on-the-branch precondition) | bd-2jkrqu: vs-5l45oz approved an UNPUSHED fix-round commit while MR !228 still held the unfixed head; the park escalation then claimed "the branch is pushed" and offered a hand merge | A transient push failure (offline, auth) parks a branch that was otherwise fine | Pushes once; **fails open** when push state is undeterminable (no `origin`, no worktree, or the worktree is not checked out on the branch — otherwise the gate would publish the checked-out branch's tip AS the PR branch); a diverged / rejected push **parks** `:head_not_pushed` with one escalation and never force-pushes. bd-bq8c8a adds the pre-fix-round half: one fetch before the implementer is dispatched, and a remote that **strictly advanced** skips the fix round and re-reviews the new head rather than producing an orphan commit that could only park here; it has no terminal of its own | 1 |
| G19 | Reviewer print-timeout → rotate to the next `review_agent.type` provider | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2356` (`handle_reviewer_print_timeout`), `apps/arbiter/lib/arbiter/worker/review_gate.ex:2364` (`rotate_reviewer`), bound `apps/arbiter/lib/arbiter/worker/review_gate.ex:2347` (`next_reviewer_provider`) | bd-3hb4ih: bd-1xss5z folded agy's own fixed `--print-timeout` into `@infra_failure_categories`, so a reviewer cut short by that CLI-internal wall parked the task outright — correct for expired credentials or a dead gateway, wrong for a wall that belongs to the CLI and that a different provider does not have | A pool entry that is merely slow costs a second provider's pass on the same diff | Rotates to the next pool entry with the IDENTICAL prompt (same diff, same round, no round and no verdict re-prompt consumed); at most one pass per pool entry per round; once every entry has timed out, **parks** `:reviewer_timeout` with one escalation naming each provider's timeout. A pool of one never rotates — G3/G4's terminal, unchanged | 1 |
| G20 | Empty net-diff guard on APPROVE (`head_sha != base_sha` but the content nets to zero) | `apps/arbiter/lib/arbiter/worker/review_gate.ex:1423` (`finalize_approval`) | bd-aq81qz / PR #1957: a task redispatched onto a branch whose commits were already squashed onto main; the worker merged main in (a real commit, so G2's SHA-equality check does not fire) but `base_sha..HEAD` is empty. The reviewer APPROVEd and only a `review-coverage write failed: :no_net_diff` warning marked the miss | A branch whose target genuinely absorbed its commits via a different route than G2 expects escalates instead of completing | Reuses `apps/arbiter/lib/arbiter/worker/review_gate.ex:3802` (`coverage_net_diff_id`)'s fingerprint attempt; its `{:error, :no_net_diff}` **parks** `:empty_net_diff` instead of recording the APPROVE, one escalation, run recorded `review_parked` | 1 |

### 2.2 `apps/arbiter/lib/arbiter/worker/watchdog.ex` — the merge guard

| # | Guard | Anchor | Protects against | Misfire mode | On failure | Patches |
|---|---|---|---|---|---|---|
| W1 | Merge-coverage decision (reviewed-SHA guard, or `decide/3` under `merge.coverage_enabled` — P4) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3165` (`guarded_merge_decision`) | bd-dxgris/#1498: merging commits nobody reviewed | The whole of chain A | Routes to W2–W6 | **4** |
| W2 | Forge-head-lag latch | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3169` (`forge_head_lagging?`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:259` (`head_lag_grace_polls`) | bd-ch9pmk/#1622: PR resource stale seconds after our own push | A push that never surfaces waits 5 polls, then falls through to W6 | `{:wait, …}`, bounded at 5 | 1 |
| W3 | Re-read the recorded stamp | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3563` (`reconsider_stale_head`) | bd-6bg54c cause B: `effective_outcome` pins `via_review_gate` to `:approved` forever, so the memo never invalidates | — | Falls through to W4 | 1 |
| W4 | Re-read the live head before deciding | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3588` (`resolve_against_live_head`) | bd-ch9pmk AC4: deciding against a head already seconds stale | A forge error keeps the previous reading | Falls through to W5 | 1 |
| W5 | Content equality (base-merge-only) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3698` (`base_merge_only?`), via `apps/arbiter/lib/arbiter/mergers/net_diff.ex:151` (`equivalent?`) | bd-6bg54c: a merge from base changes the head but not the content | **Fails closed** on any diff-fetch error → a transient forge error becomes a full re-review | Returns false → W6 | 1 |
| W6 | Unreviewed head → back to review, else page once | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3732` (`resolve_stale_reviewed_head`) | bd-6bg54c: the 303-retry loop | **Fails the worker** with `{:unreviewed_head, head}` and buys a review round — since P7 scoped by the ReviewGate to the delta since the last covered commit when one is an ancestor (§4.5), and routed through W13/W14's resume path so a fix pass still holding the family defers instead of paging; when the resume budget is spent, pages and stops | `Worker.fail` + resume, or one escalation | 2 |
| W7 | Forge atomic precondition (`expected_sha`) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1472` (`apply_guarded_merge`) | The residual poll→merge window | A racing push turns into a merge failure | **Unbounded retrying.** Retries the merge call every poll; `apps/arbiter/lib/arbiter/worker/watchdog.ex:274` (`default_merge_fail_notify_threshold`) gates only the *page*, after which **`max_polls: :infinity`** and a re-page every cadence — no terminal state | 2 |
| W8 | Latch suspension for fleet-authored pushes (update-branch only, since P7) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3916` (`clear_reviewed_latch`) | Deadlocking the fleet's own rebase/fix-pass against its own guard | The guard is **deliberately** scoped to advances the fleet did not initiate. The consequence is that the CI `fix_pass` path (`apps/arbiter/lib/arbiter/worker/watchdog.ex:1978` (`clear_reviewed_latch`)) re-latches to the fix-pass head and merges content no reviewer saw — a deliberate scoping choice, but the same shape #1498 exists to stop. §4.5 argues it should change. **P7 (bd-60r6wp / #1738) changed it:** only update-branch still suspends; a fix pass or conflict resolver keeps the approved baseline (`note_authored_push/1`) and its head is judged on content by W5/W6 | Baseline floats to the new head | 2 |
| W9 | Baseline tracking per poll | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3827` (`track_reviewed_baseline`) | Losing the baseline across polls | Re-pins to a stale head while suspended | — | 2 |
| W10 | `via_review_gate` outcome pinning | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1315` (`effective_outcome`) | A gate-approved lane whose forge shows no approval | Approval never lapses ⇒ W3's memo never invalidates (the bd-6bg54c cause-B mechanism) | — | 1 |
| W11 | CI `:not_started` grace | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1354` (`not_started_grace_polls`) | bd-aeb9wv/#1189: zero check-runs race | A no-CI repo waits 5 polls every time | Falls through to merge, bound 5 | 1 |
| W12 | Poll ceiling → `{:awaiting_review_timeout, N}` | `apps/arbiter/lib/arbiter/worker/watchdog.ex:2547` (`handle_review_timeout`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:235` (`default_max_polls_auto`) | bd-66ey1o: a lane parked forever | **12 runs, $43.27.** A slow-but-healthy CI run fails the worker | `Worker.fail` then auto-resume | 3 |
| W13 | Auto-resume budget | `apps/arbiter/lib/arbiter/worker/watchdog.ex:2639` (`attempt_auto_resume`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:306` (`default_max_auto_resumes`) | bd-8eheb6: a resumable run left for a human | Budget spent → escalate and stop | One escalation (`apps/arbiter/lib/arbiter/worker/watchdog.ex:2981` (`escalate_auto_resume_give_up`)) | 2 |
| W14 | Resume-deferral budget | `apps/arbiter/lib/arbiter/worker/watchdog.ex:2618` (`handle_resume_error`) | bd-di4t6d: resume refused by the task's own fix pass; three observed indefinite stalls | 30 deferrals ≈ 30 min of polling | One escalation `{:resume_blocked, …}` | 1 |
| W15 | Non-author-approval park | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1518` (`handle_nonauthor_approval`) | bd-c3lchp: forge requires a non-author approver; the ceiling marked it FAILED | — | Escalate once, `max_polls: :infinity` | 1 |
| W16 | Block escalation debounce | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1697` (`debounce_escalate_block`) | #1226: escalation storms | A changed block reason re-pages | Once per episode | 2 |
| W17 | Auto-resolve attempts (`behind_base`, `ci_failed`) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1841` (`maybe_escalate_unresolved`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:265` (`default_max_auto_resolve_attempts`) | #354 Phase 2a | Two failed attempts paid before escalating | Escalate, `max_polls: :infinity`, re-page per cadence (`apps/arbiter/lib/arbiter/worker/watchdog.ex:2123` (`escalate_unresolved_block`)) | 3 |
| W18 | Conflict-resolution attempts | `apps/arbiter/lib/arbiter/worker/watchdog.ex:2219` (`drive_conflict_resolution`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:299` (`default_max_conflict_attempts`) | #354 Phase 2b | A phantom conflict spends two resolver workers | One escalation (`apps/arbiter/lib/arbiter/worker/watchdog.ex:2253` (`escalate_conflict_exhausted`)) | 2 |
| W19 | Park heartbeat | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1865` (`park_heartbeat_due?`) | bd-5mzzww: a PR parked 19h on one page | Re-pages a park that is being worked | Re-page every 720 polls | 1 |
| W20 | Coverage-unknown bounded wait | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3306` (`wait_for_coverage`), bound `apps/arbiter/lib/arbiter/worker/watchdog.ex:308` (`coverage_unknown_grace_polls`) | bd-df3zlo/#1736: an `{:unknown, _}` coverage answer waited on forever | A forge whose compare API is down parks an otherwise mergeable PR after 5 polls | Park + one page (`:coverage_unknown`), no further merge for that head, and the `auto_merge` poll ceiling lifted to `:infinity` so the park cannot decay into an `{:awaiting_review_timeout, _}` re-review; a new head reopens it and restores the ceiling | 1 |

### 2.3 `apps/arbiter/lib/arbiter/workflows/merge_queue.ex` — the out-of-process queue

| # | Guard | Anchor | Protects against | Misfire mode | On failure | Patches |
|---|---|---|---|---|---|---|
| M1 | Merge-coverage refusal (reviewed-SHA guard, or `decide/3` under `merge.coverage_enabled` — P4) | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1326` (`merge_guarded`) | bd-dxgris/#1498, queue side | Same as W1, without W2–W6's recovery — the queue has **no** forge-lag wait and **no** re-read; P7 gave it W5's content check on the flag-off path (`legacy_merge_decision`, memoised per head) | Returns `{:error, {:stale_reviewed_sha, …}}` | 2 |
| M2 | Baseline precedence (recorded > latch) | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1346` (`item_reviewed_sha`) | Drifting from the Watchdog | Diverges anyway: the queue's third arm floats to `last_head_sha` while suspended | — | 2 |
| M3 | Stale-SHA retry disposition | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1763` (`try_merge`) | Parking an item at `:failed` with no way back in | **Unbounded.** Status untouched ⇒ the same refused merge is re-attempted **every tick, forever**. This is the 303+ retry shape, still live in the queue | Retries indefinitely; no escalation of its own | 1 |
| M4 | Latch suspension | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1701` (`clear_reviewed_latch`) | The queue's own rebase/resolver push deadlocking the guard | Same hole as W8 — closed by P7 the same way: the resolver push no longer suspends | — | 1 |
| M5 | Per-poll baseline tracking | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1729` (`track_reviewed_baseline`) | — | Mirror-maintained by hand against W9 | — | 1 |
| M6 | Suspension lift condition | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1652` (`latch_suspended?`) | An unreadable head lifting the suspension early | Hand-mirrored against the Watchdog's copy | — | 1 |
| M7 | Item status short-circuits | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:762` (`poll_item`) | Re-polling terminal items | A `:failed` item has no way back in | Terminal | — |
| M8 | Coverage-unknown bounded wait (queue) | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1501` (`wait_for_coverage`), bound `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:247` (`coverage_unknown_grace_ticks`) | bd-df3zlo/#1736, queue side | Same as W20 | Park + one page, and the parked head short-circuits `merge_guarded` before any forge call | 1 |

### 2.4 `apps/arbiter/lib/arbiter/worker.ex` — the worker commit gate and the fix-round dispatcher

| # | Guard | Anchor | Protects against | Misfire mode | On failure | Patches |
|---|---|---|---|---|---|---|
| C1 | bd-ofql8k commit gate (`:uncommitted` / `:no_commits` / `:secret_in_commit`) | `apps/arbiter/lib/arbiter/worker.ex:3510` (`commit_gate`) | A worker printing `arb done` over uncommitted or absent work; committed agent-config bearer tokens | Non-branch worktrees would false-positive, hence the branch check; git errors | **Fails open** on git error; otherwise diverts to a nudge relaunch | 3 |
| C2 | Rejection parking | `apps/arbiter/lib/arbiter/worker.ex:5261` (`park_rejected`) | — | Since P9, `park_rejected/4` takes a park reason: with one it writes `Run.status = :review_parked` and pages once; without one (a genuine REQUEST_CHANGES only) it is the pre-P9 `Run.status = :failed` via `apps/arbiter/lib/arbiter/worker.ex:5279` (`fail_reason_for`) | `fail_now` | 2 |
| C3 | Fix-round budget and non-convergence digest | `apps/arbiter/lib/arbiter/worker.ex:5325` (`maybe_dispatch_fix_round`) | bd-a9zb7w: a rejection nobody scheduled an implementer for | Identical-findings digest stops the loop — the one guard already shaped the way §5 wants | One escalation | 2 |
| C4 | `{:awaiting_review_timeout, N}` → `review_not_started` | `apps/arbiter/lib/arbiter/worker.ex:1538` (`awaiting_review_timeout`) | bd-8tjcms/#1511: a resumable timeout recorded as `:failed` | — | Terminal non-failure status | 1 |

### 2.5 ReviewPatrol and PRPatrol

| # | Guard | Anchor | Protects against | Misfire mode | On failure | Patches |
|---|---|---|---|---|---|---|
| R1 | Head-advance detection | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:900` (`maybe_record_head_sha`) | Re-reviewing an unchanged PR | Shares `last_reviewed_sha` with the merge guard — **the same column, different meaning** (engagement cursor vs merge authorisation) | — | 2 |
| R2 | CI-settle gate | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:2419` (`ci_settled?`) | Reviewing mid-pipeline | A never-settling pipeline defers forever (no bound) | Skip this tick | 1 |
| R3 | Debounce window | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:2424` (`debounced?`) | Review spam on rapid pushes | Delays a genuine re-review | Skip this tick | 1 |
| R4 | Per-PR review cap | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:953` (`review_capped?`), handler `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:972` (`handle_review_cap`) | bd-ahvk03: unbounded review spend on one PR | A busy PR freezes until a human intervenes | **Fail-closed, one escalation**, frozen | 2 |
| R5 | Atomic escalation claim | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:1000` (`claim_review_cap_escalation`) | bd-4po0nv: 7 identical escalations in ~3s | — | — | 1 |
| R6 | Relevance gate | `apps/arbiter/lib/arbiter/workflows/review_patrol.ex:1062` (`gate_on_relevance`) | Re-reviewing irrelevant new commits | A relevant change judged irrelevant | Skip | 1 |
| P1 | Dispatch-attempt bound | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:129` (`max_dispatch_attempts`), recorded at `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:514` (`record_dispatch_failure`) | bd-7rxwzc: 22 tickets for one PR in ~28h | A transient repo-resolution outage permanently gives up on a PR | **Fail-closed, one final escalation, `given_up`** — the reference implementation of the policy in §5 | 2 |
| P2 | Give-up blocking | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:495` (`backing_off?`) | A given-up PR resuming after backoff | Requires human/config intervention | Unconditional block | 1 |
| P3 | Re-escalation throttle | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:523` (`escalate_dispatch_failure`) | bd-dtpjlf: silence after the first page | Hourly re-page on a known-broken repo | ≤1/hour, plus one unconditional final | 1 |
| P4 | Follow-up dedupe | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:839` (`deduped?`) | bd-5g6rw4: duplicate follow-ups | A zombie worker blackholes the PR — hence P5 | Skip | 2 |
| P5 | Zombie-idle unblocking | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:853` (`still_blocking?`) | lt-c9td4r: a crashed dispatch blackholing every future trigger | A genuinely-idle healthy worker read as a zombie | Allow re-file | 1 |
| P6 | Answered-thread rejection | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:700` (`reject_answered_threads`) | bd-45x4yo: re-filing an already-answered thread (5 tasks, ~$8–11) | A thread we answered but that still needs work is dropped | Skip | 1 |
| P7 | Author allowlist | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:685` (`author_allowed?`) | Patrolling third-party PRs | — | Skip | 1 |
| P8 | ReviewGate branch hold | `apps/arbiter/lib/arbiter/workflows/pr_patrol.ex:366` (`review_gate_holds?`), decided by `apps/arbiter/lib/arbiter/reviews/gate_activity.ex:98` (`engaged`) | bd-bq8c8a: patrol's fix worker pushed to a branch whose task was still inside the ReviewGate; the gate's round-1 implementer then committed a sibling, its push was rejected `:diverged`, and the task parked `head_not_pushed` | A gate that never converges holds the PR's follow-ups for as long as it runs (the threads stay unresolved, so nothing is lost — the first tick after it converges files them) | **Fail closed** — holds on `:awaiting_review_gate`, a running round, `:review_parked`, *and* on a failed read (`:undeterminable`), because this guard authorises *filing* (§5.2). Skip this tick; nothing written, nothing consumed | 1 |

### 2.6 What the inventory shows

Counting the 64 rows above:

* **Four independent implementations of "has this commit been reviewed?"** —
  W1–W6, M1–M6, R1, and ExternalReview's baseline write
  (`apps/arbiter/lib/arbiter/reviews/external_review.ex:1418`
  (`last_reviewed_sha`)). Two of them (Watchdog, MergeQueue) are hand-maintained
  mirrors, and M1 is already missing W2, W4 and W5.
* **One column, two meanings.** `last_reviewed_sha` is simultaneously
  ReviewPatrol's "engagement cursor" (R1) and the merge guard's "authorisation
  baseline" (W3, M2). A patrol tick can move a merge authorisation.
* **Two guards retry without any bound: M3 and W7.** M3 leaves the queue item's
  status untouched, so the same refused merge is re-attempted every tick. W7's
  *paging* is bounded (`apps/arbiter/lib/arbiter/worker/watchdog.ex:274`
  (`default_merge_fail_notify_threshold`), then a cadence) but its *retrying* is
  not: the error arm of `apply_guarded_merge/2` only increments a counter
  (`apps/arbiter/lib/arbiter/worker/watchdog.ex:1287` (`merge_fail_count`)) and
  re-issues the merge call on the next poll, and the paging branch lifts
  `apps/arbiter/lib/arbiter/worker/watchdog.ex:1331` (`max_polls`) to `:infinity`
  so the polls never run out. W17 lifts `max_polls` the same way but *is* bounded
  on attempts (`apps/arbiter/lib/arbiter/worker/watchdog.ex:265`
  (`default_max_auto_resolve_attempts`)) and merely watches afterwards; that is
  the class-E shape, and it does not cover W7. Every other bound exists; they are
  simply scattered across ten module attributes with no shared vocabulary.
* **Four guards convert a guard decision into a failed run** — G14's
  genuine-REQUEST_CHANGES-at-the-round-cap arm, C2 (the conversion point G14
  routes through), W6 and W12. It was thirteen; P9 (bd-9zuvbh) took ten of them
  — G2, G3, G6, G8, the four verdict-guard terminal arms (G9, G10, G11, G12),
  G15 and G16 — and made them **park** instead, which is the mechanism that was
  behind most of the `$325.82`. The content side of all ten is unchanged: a
  malformed or guard-rejected APPROVE still never merges. The remaining four are
  P10's class-audit inventory.
* **One guard trades correctness away on purpose:** W8/M4 suspend the check for
  fleet-authored pushes — deliberately, to stop the fleet deadlocking against its
  own rebase — and the CI `fix_pass` path uses the same exemption, so a
  post-approval `fix_pass` commit merges with no review round having seen it. The
  exemption is right for content-preserving pushes and wrong for content-changing
  ones, and today it cannot tell them apart. *(P7, bd-60r6wp / #1738, closed
  this: the exemption now covers update-branch alone, and the fix-pass /
  conflict-resolver head is judged on content — see §4.5.)*

---

## 3. The review-coverage model

### 3.1 Shape

One append-only table. Nothing mutates a row; a new approval adds a row.

```elixir
# Arbiter.Reviews.Coverage.Entry
%{
  id:           uuid,
  task_id:      "bd-6woz0x",              # the AUTHORING task, always
  mr_ref:       "ryanrborn/arbiter#1631", # the PR this coverage is about
  head_sha:     "8e7a69ea…",              # 40 hex, the commit covered
  base_ref:     "main",                   # what the net diff was taken against
  net_diff_id:  "e3d29b52…",              # NetDiff.fingerprint(base...head_sha)
  kind:         :reviewed | :mechanical | :operator,
  source:       :review_gate | :review_patrol | :external_review | :watchdog | :cli,
  round:        2 | nil,                  # ReviewGate round, when applicable
  derived_from: uuid | nil,               # :mechanical rows name their parent
  covered_at:   ~U[…]
}
```

Three `kind`s, and the distinction is load-bearing:

* **`:reviewed`** — an approving review round covered this exact commit. Only
  ever written by a verdict that reached `{:approve, _}` *after* every verdict
  guard passed (§2.1 G9–G12). A guard's `fail_closed` is a reject and writes
  nothing.
* **`:mechanical`** — the fleet itself produced this head from an
  already-covered one by an operation that provably changed no content:
  `NetDiff.fingerprint(base...new_head) == NetDiff.fingerprint(base...parent)`.
  A base merge, a rebase-forward, a force-push of identical content. This is the
  *only* legitimate way a commit becomes mergeable without a review round, and
  it is written **only when the fingerprint proves it** — never speculatively.
* **`:operator`** — a human authorised this head explicitly
  (`arb review cover <task> <sha> --reason "…"`). This is the audited
  replacement for "the operator had to merge all five by hand": the escape hatch
  becomes a recorded decision rather than an out-of-band action the system never
  learns about.

`issues.last_reviewed_sha` stays, demoted to what it always meant on the patrol
side: ReviewPatrol's engagement cursor (R1). It stops being read by any merge
path — which alone resolves the "one column, two meanings" collision in §2.6.

### 3.2 The predicate

```elixir
@spec decide(coverage :: [Entry.t()], head :: String.t() | nil, ctx :: ctx()) ::
        {:covered, String.t()}
        | {:uncovered, :authored_content | :no_coverage}
        | {:unknown,
           :forge_lagging
           | :ancestry_unavailable
           | :diff_unavailable
           | :no_base_ref
           | :no_head}
```

Resolved in order; the first hit wins:

1. `head ∈ coverage.head_sha` → **`{:covered, head}`**.
2. `ctx.local_head_sha ∈ coverage.head_sha` **and** `head ≠ ctx.local_head_sha`
   **and** `head` is an *ancestor* of `ctx.local_head_sha` →
   **`{:unknown, :forge_lagging}`**. The forge is behind our own push. Ancestry
   is what makes this safe and is strictly better than today's
   "have we ever seen our head echoed" boolean: it is decidable on the first
   poll rather than after up to 5, and it cannot be satisfied by an unrelated
   commit.

   The probe is three-valued (P4, bd-df3zlo / #1736): a `true` proves the lag,
   a `false` disproves it and falls through to the content rules, and a probe
   that was *asked and could not answer* — an API error, a timeout, an
   unrecognised shape — stops here as **`{:unknown, :ancestry_unavailable}`**.
   With the lag question open, the content rules below would be answering a
   different question than the one that was asked, so a probe failure yields a
   pause and can never yield `covered`. A ctx that supplies **no** probe is a
   caller that has declared it cannot ask: rule 2 is unreachable for it and
   rules 3-6 decide, exactly as in P3.
3. `NetDiff.fingerprint(base...head) ∈ coverage.net_diff_id` →
   **`{:covered, head}`**, and a `:mechanical` row is written for `head`
   naming the matched row as `derived_from`. This subsumes W5 `base_merge_only?`
   and extends it to rebases and identical force-pushes for free.
4. Diff fetch failed, or no `base_ref` → **`{:unknown, :diff_unavailable}`** /
   **`{:unknown, :no_base_ref}`**. Today W5 folds these into "not equivalent",
   i.e. a transient forge error buys a full re-review.
5. Coverage set empty → **`{:uncovered, :no_coverage}`**.
6. Otherwise → **`{:uncovered, :authored_content}`**.

`{:unknown, _}` is not a decision. It is a *pause*, bounded by the guard class
policy (§5, class A: N = 5 polls), after which it resolves to the class's
fail-closed side: escalate once and park. It never merges and never fails the
run.

### 3.3 Where coverage is stamped

One writer module, `Arbiter.Reviews.Coverage`, with one `record/1`. Every site
below calls it and nothing writes coverage any other way:

| Site | Today | Becomes |
|---|---|---|
| ReviewGate clean approve | `apps/arbiter/lib/arbiter/worker/review_gate.ex:3678` (`stamp_reviewed_head`) writes `last_reviewed_sha` | `Coverage.record(kind: :reviewed, round: state.round, net_diff_id: …)` — **and the write is no longer best-effort**: a failed write must page, because a silently-missing row *is* the #1585 stall |
| ReviewGate verdict guards | — | nothing (a `fail_closed` is a reject) |
| ReviewPatrol post-review | `last_reviewed_sha: head` on the engagement | `Coverage.record(kind: :reviewed, source: :review_patrol)` on the **authoring task**, plus the engagement cursor as today |
| ExternalReview baseline | `apps/arbiter/lib/arbiter/reviews/external_review.ex:1418` (`last_reviewed_sha`) | `Coverage.record(kind: :reviewed, source: :external_review)` when the external verdict is an approval; cursor only otherwise |
| Watchdog fleet push (update-branch / rebase) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3916` (`clear_reviewed_latch`) suspends the guard | `Coverage.record(kind: :mechanical, …)` **only if** the fingerprint matches; otherwise nothing is recorded and the new head is honestly uncovered |
| Watchdog CI `fix_pass` | `apps/arbiter/lib/arbiter/worker/watchdog.ex:1978` (`clear_reviewed_latch`) — merges unguarded | nothing. A `fix_pass` changes content by construction, so its head is `:uncovered` and routes to a scoped re-review. **This closes the hole in §2.6.** **P7 ✅ (bd-60r6wp / #1738)** |
| MergeQueue conflict resolver push | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1701` (`clear_reviewed_latch`) | fingerprint test; a conflict resolution that wrote content is uncovered, exactly as `NetDiff`'s moduledoc already argues **P7 ✅ (bd-60r6wp / #1738)** |
| Operator | out-of-band hand-merge | `arb review cover` → `kind: :operator` |

### 3.4 How the merge check reads it

Both merge paths collapse to one call.

```elixir
# Watchdog.guarded_merge_decision/1 and MergeQueue.merge_guarded/2
case Coverage.decide(coverage, head, ctx) do
  {:covered, sha}      -> {:merge, sha}       # sha is the forge's expected_sha
  {:unknown, reason}   -> {:wait, reason}     # bounded by class A's N
  {:uncovered, reason} -> {:review, reason}   # one re-review, then escalate once
end
```

The sketch above elides one thing the implementation makes explicit: a rule-3
match also *implies a `:mechanical` row*. Adopters (P3/P4) must call
`Coverage.decide_with_record(coverage, head, ctx)`, which returns
`{decision, record_or_nil}`, and persist the returned row via `Coverage.record/1`
— otherwise §4.2's "the next base merge resolves at rule 1" never kicks in and
every poll re-fingerprints. `Coverage.decide/3` is the convenience form for call
sites that only want the decision.

`expected_sha` (W7) survives unchanged — the forge's atomic precondition is a
different guarantee from coverage and closes the residual poll→merge window. The
model replaces the *authorisation* layer, not the *atomicity* layer.

Everything else in §2.2's W1–W6 and §2.3's M1–M6 is deleted: the latch, the
suspension, the memo, the memo invalidation, the grace counter, the hand-mirrored
copy in the MergeQueue. That is roughly 400 lines across the two files, replaced
by one table, one predicate and one writer.

---

## 4. Walkthroughs

Each case states what happens today and what the model does. "Correct outcome"
is the operator's judgement from the incident report, not this design's opinion.

### 4.1 Chain A link 1 — bd-dxgris / #1498: a genuinely unreviewed push (cause A)

Reviewer approves `A`. A human (or another process) pushes `B` with real content
while the forge still reports `approved: true`.

* **Coverage:** `{head_sha: A, net_diff_id: fp(A)}`. Head is `B`. Rule 1 misses;
  rule 2 misses (`B` is not an ancestor of anything we pushed); rule 3 misses
  (`fp(B) ≠ fp(A)` — `B` has content); rules 4–5 do not apply. →
  `{:uncovered, :authored_content}`.
* **Outcome:** do not merge; dispatch one review round on `B`; if that budget is
  spent, escalate once and park. **Correct — cause A stays blocked.** This is
  the property the whole design has to preserve, and it is preserved by rule 3
  being a *content* test rather than a topology test.

### 4.2 Chain A link 2 — bd-6bg54c / #1585: five approved PRs, 303+ retries

Reviewer approves `A`. `main` moves; the fleet merges base into the branch,
producing `M`. `fp(main...M) == fp(main...A)` — this is measured, not assumed:
the incident report records `git diff origin/main...<sha> | git patch-id --stable`
producing the identical `e3d29b52…` for both.

* **Today:** `ReviewedSha.check(A, M)` → `{:error, {:stale_reviewed_sha, A, M}}`.
  The Watchdog retried ~1/min **forever** (303+ on one PR) and re-paged every 30;
  the MergeQueue still does, unbounded (M3). The operator hand-merged five PRs.
* **Coverage:** rule 1 misses, rule 2 misses, **rule 3 hits** → `{:covered, M}`,
  and a `:mechanical` row is written for `M` with `derived_from` = `A`'s row.
* **Outcome:** merges on the first poll. No retry loop, no page, no hand-merge.
  The `:mechanical` row also means the *next* base merge resolves at rule 1.

### 4.3 Chain A link 3 — bd-ch9pmk / #1622: the APPROVED fix round

Round 1 `REQUEST_CHANGES` on `S1`. The implementer pushes `S2`. Round 2
`APPROVE` on `S2`, stamped at 21:58:11. The worker pushes at 21:58:11. The
Watchdog polls at 21:58:16 and GitHub's PR resource still reports `S1`.

* **Today:** two different bugs, depending on which patch you are standing on.
  Before #1614: `check(S2, S1)` → `{:error, {:stale_reviewed_sha, …}}` →
  `Worker.fail({:unreviewed_head, S1})` → a full redundant re-review, every
  cycle. After #1614: a boolean latch with a 5-poll grace counter suppresses the
  decision until the forge echoes `S2`.
* **Coverage:** rule 1 misses (`S1` is not covered — round 1 *rejected* it).
  **Rule 2 hits**: `local_head_sha = S2` is covered, and `S1` is an ancestor of
  `S2`. → `{:unknown, :forge_lagging}` on the *first* poll, with no grace
  counter and no per-worker latch state. Next poll reports `S2` → rule 1 →
  merge.
* **Outcome:** merges. No `{:unreviewed_head, …}`, no redundant re-review, and
  critically: because round 1's `S1` was a *reject*, `S1` is not in the coverage
  set, so the pre-#1614 "merge the pre-fix-round commit" failure — the worse half
  of the same confusion, which the #1614 comment explicitly warns about — is
  structurally impossible rather than avoided by a latch.

### 4.4 Chain A link 4 — bd-2eyf9y / #1594: the fix-round commit gate

A fix round ends with HEAD unchanged. Three outcomes today (G15/G16): resume
once with a commit instruction; escalate `:uncommitted`; escalate `:no_changes`
— plus a fourth message shape added by bd-c6tdbu for the
`no_changes_after_approval_gap` case.

* **Coverage:** the gate's real question is "does this round contribute content
  the last review did not see?" — which is `fp(base...head_now) ≠
  fp(base...head_at_last_review)`, the same primitive as rule 3. An uncommitted
  worktree and an unchanged HEAD both answer "no new content", so they stop
  being two different escalations: **one predicate, one escalation, two
  remediation sentences.**
* **Outcome:** the commit gate stays (it is a genuine progress guard, class D),
  but it shrinks to a fingerprint comparison plus a nudge, and its "no changes"
  branch no longer has to special-case the approval gap — an APPROVE that was
  rejected only for an undispositioned non-blocking observation produces
  `fp` equality, escalates once, and the human decides, which is what bd-c6tdbu
  asked for anyway.

### 4.5 Post-approval CI `fix_pass` — the case the current design gets wrong

Round 2 approves `S2`. CI fails on `S2`. The Watchdog dispatches a fix-pass
worker, which pushes `S3` with real content.

* **Today:** `apps/arbiter/lib/arbiter/worker/watchdog.ex:1978` (`clear_reviewed_latch`) **suspends** the guard for the fleet's own push, then
  `track_reviewed_baseline/2` re-latches to `S3` once the head moves. `S3` merges
  with no review round having seen it. The suspension is deliberate and
  necessary — without it the fleet deadlocks against its own rebase — but it is
  scoped by *who pushed* when the question is *what changed*, and those diverge
  exactly here.
* **Coverage:** no row is written for `S3` (rule 3 fails — a CI fix changes
  content). Rule 1 misses. Rule 2 misses (`S3` is a *descendant* of our covered
  head, not an ancestor; the lag rule is deliberately one-directional). →
  `{:uncovered, :authored_content}` → one review round scoped to `S2..S3`.
* **Outcome:** the fix-pass diff gets reviewed. This is a **behaviour change
  that costs money** — a review round that does not happen today — and it is the
  correct trade: the alternative is that any content the fleet authors after
  approval merges unreviewed. The round is scoped to the delta
  (`S2..S3`), the same new-diff-only compare ReviewPatrol already uses, so it is
  a small round, not a full re-review.

**As built (P7, bd-60r6wp / #1738).** Both merge paths, flag on or off:

* **Nothing stamps `S3`.** A fix pass or conflict resolver no longer suspends
  the latch (`note_authored_push/1` in the Watchdog and the MergeQueue); the
  approved baseline stays pinned, so the legacy guard sees `S2 ≠ S3` and asks
  W5's content question instead of re-latching onto `S3`. An update-branch
  still suspends, but not once an authored push is pending — otherwise the
  merge commit carrying the unreviewed fix would be the head it re-latched on.
  With the flag off, the shadow therefore records `uncovered → uncovered`
  (agree) for this shape, not the `covered → uncovered` P3 caught.
* **Content-equal `S3` merges on a `:mechanical` row.** When W5 (or, on the
  queue's flag-off path, its new mirror) proves the net diff unchanged, the
  merge proceeds pinned to `S3` and records the row rule 3 implies
  (`Coverage.mechanical_for_diff/5`, derived from the covered row whose
  fingerprint matches). Flag on, rule 3 writes it as before.
* **Content-changing `S3` goes to a delta round.** W6 fails the worker with
  `{:unreviewed_head, S3}` and resumes it through the same path the W12
  timeout uses, briefed to hand straight back to the ReviewGate. The gate,
  seeing that `S3` descends from a covered commit, scopes the reviewer to the
  branch's own commits in `S2..S3` (`git log --first-parent --no-merges -p`,
  inlined in the prompt) instead of the whole branch. Its APPROVE writes the
  `:reviewed` row for `S3` (fingerprinting the whole PR, as always), and the
  next Watchdog merges `S3` at rule 1. A rebased `S3` (the resolver's usual
  output) has no commit range to scope to and gets the whole-branch review.
* **The queue** has no review route of its own: an authored resolver head is
  refused (M3, still unbounded until P6) until a review covers it.

#### 4.5.1 The same scenario, one step earlier: the resume that never re-fired (bd-985tkl)

Before `S3` can be reviewed at all, the fix pass has to hand the task back. It
did not, twice in one day (bd-3qkbch / #1724, bd-bsdeb2 / #1732): the Watchdog
hit its poll ceiling *while the fix pass it had dispatched was still running*,
logged `transition=auto_resume outcome=deferred blocked_by="<task>:fixpass"
deferral=1/30`, and then produced nothing at all for 70+ minutes on an approved,
CI-green, `MERGEABLE CLEAN` PR. A coordinator recovered both by hand.

The deferral (W14) was the right policy; what broke was the process that owned
it. `Dispatch.resume/2` calls `stop_prior_worker/1` **before** `Worker.start/1`'s
family check refuses, so the primary worker the Watchdog monitors exits as a
direct consequence of the resume attempt that was just deferred. The Watchdog's
`:DOWN` clause then stopped it and took the `:retry_review_resume` timer with
it — a bounded retry with nothing left to run it, which is invariant **I1**'s
"named bound and a terminal state" failing in the other direction: not an
unbounded retry, an unreachable one.

The fix keeps W14 in class E and makes its terminal real:

* a deferral in flight outlives the worker it was watching, and drops stray
  `:poll` ticks (a `Github.Error kind: :network` "socket closed" appeared 22
  times in three hours during the incident) so a forge hiccup can neither clear
  the deferral nor mint a second retry chain;
* the blocking pass is monitored, so the retry fires on its completion rather
  than only on a tick;
* both terminal arms — the deferral budget running out, and a blocker that is
  already dead — **park** the task (`review_park_reason: resume_blocked`) and
  page once through the park claim, which is class E's "parked and still
  watched" terminal and invariant **I2**: the run is not re-failed and nothing
  is merged.

P7 extends that fix to the step after it. W6's review-round resume used to be
a private copy that paged `{:resume_failed, _}` and stopped when the family
check refused it — the same stranding, one step later, on exactly the head a
fix pass had just pushed. It now goes through the shared resume path, so a fix
pass still holding the family defers, re-fires on its `:DOWN`, and parks and
pages once at the bound.

### 4.6 Chain B — the verdict parser (bd-6dxit2 → bd-869mmg → bd-1xss5z → bd-c6tdbu)

The coverage model does **not** fix verdict parsing, and this design does not
claim it does. Chain B is a different defect class: the gate cannot tell what the
reviewer said. What the design changes is the *consequence*.

| Link | Today | Under the policy (§5, class C) |
|---|---|---|
| bd-6dxit2 / bd-869mmg — verdict present on disk, missed by the scan | `:review_gate_inconclusive`, **run failed**, worktree work stranded, 52 runs / $226.97 | G7 `recover_verdict_from_scans` runs (kept); if it still cannot parse, the round is recorded `verdict: :timed_out`-style honestly, **one escalation**, PR parked, **run not failed** |
| bd-1xss5z — agy's print timeout truncates the review | Cut-off turn recorded as "gemini session SUCCESS" → inconclusive → failed run | Same: one escalation, parked. The truncation is still a bug to fix; it stops costing a run |
| bd-c6tdbu — honest APPROVE rejected over "non-blocking observations" | G10 fail-closed → forced fix round → nothing to fix → `:review_gate_inconclusive` → failed run | G10 still fail-closed on *content* (do not accept the APPROVE), but class C's liveness rule means the fix round that finds nothing to do escalates **once** to a human instead of failing the run. §4.4's fingerprint makes "nothing to do" a fact rather than an inference |
| bd-3hb4ih (open) | fifth patch | routes here under the freeze |

The point of the table: chain B's four links all end in the same place — a
**failed run on work that was fine** — and that ending is a policy choice, not a
parsing problem. Class C removes it without touching the parser.

**Shipped (P9, bd-9zuvbh/#1650):** every class-C terminal in
`worker/review_gate.ex` now reports `{:parked, reason, findings}` instead of a
verdict the author fails the run on. `Arbiter.Worker.park_rejected/4` writes
`Run.status = :review_parked` (a terminal non-failure, the `:review_not_started`
shape), stamps `issues.review_park_reason` via `Arbiter.Tasks.ReviewPark`, and
pages the coordinator **once** — the park row itself is the episode claim, so a
re-report of the same reason is silent. The four shapes above are replayed one
test each in
`apps/arbiter/test/arbiter/worker/review_gate_chain_b_replay_test.exs`. Content
is untouched: a malformed or guard-rejected APPROVE is still never accepted and
still never merges.

### 4.7 The five current failure reasons, mapped

| Reason | Runs / cost | Under the model |
|---|---|---|
| `:review_gate_inconclusive` | 52 runs, $226.97 | Class C: one escalation, parked, **run not failed**. Parsing bugs still occur; they stop being billable run failures |
| `{:awaiting_review_timeout, 30}` | 12 runs, $43.27 | Class E: W12's ceiling keeps its bound, but the terminal state is parked+escalated, never `:failed` on an approved PR (W13/W14's budgets already do this; C4 already has the non-failure status — the design makes it the rule rather than one lane's special case) |
| `{:unreviewed_head, <sha>}` | (chain A link 3) | Never produced for a lag; §4.3 resolves at rule 2. Produced only for §4.1/§4.5 genuine cases, where it is correct, and routes to one review round then one escalation |
| `{:stale_reviewed_sha, …}` | 303+ retries on one PR; 5 hand-merges | Never produced for a base merge (§4.2, rule 3). M3's unbounded retry is deleted with the guard |
| `review_not_started` | — | Unchanged; it is already the correct shape (a terminal non-failure) and becomes the template for class C/E terminal states |

---

## 5. One failure policy

### 5.1 The two invariants

**I1 — Nothing retries indefinitely.** Every refusal path has a named bound `N`
and a terminal state. Today **M3 and W7** have none. Both lift or ignore their
poll ceiling and re-page on a cadence: bounded *paging*, unbounded *retrying*.
W17 lifts `max_polls` the same way but is bounded on *attempts*, which is the
distinction the policy turns on — watching a parked item forever is fine, and is
class E's terminal state; re-issuing the action forever is not.

**I2 — A guard never strands approved work as a failed run.** When a guard gives
up, the terminal state is **parked + escalated once**, with the run recorded as
a terminal non-failure (the `review_not_started` shape, C4). `Run.status =
:failed` is reserved for work that actually failed.

Two supporting rules:

**I3 — One escalation per episode**, keyed by `{task_id, mr_ref, guard,
episode}`, where `episode` is the guard's own reset condition (block reason
changes, head moves, round advances). R5's atomic claim is the reference
implementation.

**I4 — A guard that is not in the registry does not exist.** §5.4.

### 5.2 Fail-open vs fail-closed, defined

The two terms are only meaningful once you say *what* fails open.

* **Fail open** = when the guard cannot decide, **do not block the work and do
  not spend more money**. Let the process continue in its last good state, and
  escalate once. Applies to guards that protect *spend and liveness*.
* **Fail closed** = when the guard cannot decide, **do not take the irreversible
  action**, and escalate once. Applies to guards that protect *authorisation* —
  merging, filing, publishing.

Both forms escalate exactly once and both park. Neither ever fails the run.
"Fail closed" has never meant "retry forever", and the confusion between those
two is most of chain A.

### 5.3 Guard classes

| Class | Guards | Policy | N | Terminal state |
|---|---|---|---|---|
| **A — merge authorisation** | W1–W7, M1–M3, the coverage predicate, `expected_sha` | **Fail closed** with one escalation | *Predicate:* `{:unknown, _}` bounded at **5 polls**; `{:uncovered, _}` → **1** review round. *Merge call* (W7's `expected_sha`, M3's refused merge): **5 consecutive failed merge attempts** | Parked, coverage gap named, PR mergeable by a human or by `arb review cover` |
| **B — review admissibility** | G1, G2, G18 | **Fail open** with one escalation | **1** | Review proceeds (or is skipped); a git/forge error never strands a completion. G2 changes: an absorbed branch completes with an escalation instead of a `:request_changes` run failure |
| **C — verdict integrity** | G5–G13 | **Closed on content** (never accept a malformed APPROVE) + **open on liveness** (never fail the run) | **1** re-prompt per guard, **1** escalation | Round recorded honestly (`converged: false`), PR parked, human decides |
| **D — progress** | G14, G15, G16, C1, C3 | **Fail open** with one escalation | **1** nudge / **cap** rounds, plus C3's identical-findings digest | Parked; never re-dispatch an identical round |
| **E — remediation** | W11–W19, M7 | **Fail open** with one escalation | 5 / 30 / 2 / 3 / 2 / 30 as today | Parked and still watched (`max_polls: :infinity` is fine — it is *watching*, not *retrying*), re-paged on the heartbeat only |
| **F — filing & escalation** | R2–R6, P1–P8 | **Fail closed** with one escalation | R4's review cap; P1's 5 attempts; P8's one evaluation per tick | Frozen / `given_up` / skipped; requires human or config action (P8 clears itself when the gate converges) |

Why each side:

* **A is closed** because merging is irreversible and the incident it prevents
  (#1498) is a real correctness hole. But it is closed *with a terminal park*,
  not with a retry: the 303-retry loop and the five hand-merges both came from
  treating "refuse" as "try again in a minute".

  (Class C landed in P9; see the note at the end of §4.6.)

  Class A carries **two distinct bounds**, because it answers two distinct
  questions and today only the first is bounded at all. The **coverage
  predicate** bound (5 polls / 1 review round) governs *"may this head merge?"*.
  The **merge-call** bound governs *"did the forge accept the merge we were
  authorised to make?"* — W7's `expected_sha` precondition failing, or M3's
  refused merge. That path is unbounded today; under the policy it parks after
  `N = 5` consecutive failures, escalates once, and stops re-issuing the call.
  The Watchdog may keep *watching* the PR after that (`max_polls: :infinity` is
  fine for watching, per I1) but must not keep *merging*. `merge_fail_count`
  already counts exactly the right thing — it just gates the page rather than a
  terminal state.
* **B is open** because a git hiccup that blocks a finished, committed piece of
  work costs a whole run and protects nothing — the review is a quality gate,
  not an authorisation gate, and the authorisation gate (A) is still downstream.
* **C is split** because the two halves answer different questions. "Should this
  APPROVE merge?" must fail closed — bd-6r8caj and bd-4yhv4x are real. "Should
  this run be marked failed?" must fail open — that is the entire $226.97.
* **D and E are open** because they are self-healing attempts. A failed
  self-heal should leave the system exactly where it was before the attempt,
  plus one page.
* **F is closed** because filing and escalating are outward-facing and their
  failure mode is spam: bd-7rxwzc's 22 tickets, bd-8lnnnt's 14 escalations in 75
  minutes, bd-brwx7w's ~1/min. P1 already implements this class correctly and is
  the template.

### 5.4 The registry — what makes the freeze enforceable

A policy in a doc does not stop the next guard. The mechanism is one list,
modelled on `apps/arbiter/lib/arbiter/worker/review_gate.ex:2746` (`verdict_guards`), which already proves the pattern works for four guards:

```elixir
# Arbiter.Reviews.GuardRegistry
@guards [
  %{id: :merge_coverage,  class: :a, bound: {:polls, 5},     episode: {:task, :mr_ref, :head_sha}},
  %{id: :fix_round_budget, class: :d, bound: {:rounds, :cap}, episode: {:task, :round}},
  …
]
```

Two tests give it teeth:

1. **Completeness** — every module in the control plane that returns a refusal
   (a `{:error, …}` or an escalation from a guard function named in the
   registry's `:sites` list) has a registry row. A new refusal path without a row
   fails the suite.
2. **Policy conformance** — every row has a class, a finite bound, and an
   episode key; no class-A or class-F row may reach `Worker.fail/2`; no row may
   have `bound: :infinity`.

This is the only part of the design that is *about* the guard-begets-guard loop
rather than about a specific bug, and it is the part most likely to still be
paying for itself in six months.

**Shipped (P8, bd-2u5qsj/#1647):** `apps/arbiter/lib/arbiter/reviews/guard_registry.ex`
carries one row per §2 guard — all 60 — with class, finite bound, episode key,
terminal state and sites. Completeness is enforced by an AST scan
(`apps/arbiter/test/support/guard_refusal_scan.ex`) rather than a hand-kept list,
so a refusal path added to any of the six modules fails
`apps/arbiter/test/arbiter/reviews/guard_registry_test.exs` until it is declared.
The rows that break this section's policy today — M3's and W7's unbounded merge
retries, R2's unbounded CI-settle defer, W6's class-A `Worker.fail/2`, and the
guards §2.6 counts as failing runs — are recorded in
`GuardRegistry.known_violations/0`, each naming the phase above that removes it.
That list is frozen by test: it may shrink, never grow. **P9 shrank it by ten**
(G2, G3, G6, G8, G9–G12, G15, G16 now declare `terminal: :parked`); the four
`:failed_run` rows left are G14, C2, W6 and W12.

---

## 6. Consolidation plan

### 6.1 Collapses into the coverage model

| Deleted | Anchor | Replaced by |
|---|---|---|
| `ReviewedSha.check/2` and `latch/3` | `apps/arbiter/lib/arbiter/mergers/reviewed_sha.ex:82` (`check`) | `Coverage.decide/3` rules 1–6 |
| Watchdog latch/suspension/memo (`reviewed_sha`, `recorded_reviewed_sha`, `recorded_sha_loaded?`, `cleared_recorded_sha`, `latch_suspended_at_head`, `head_lag_polls`) | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3827` (`track_reviewed_baseline`) | coverage rows |
| `forge_head_lagging?` + grace counter | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3169` (`forge_head_lagging?`) | rule 2 (ancestry) |
| `reconsider_stale_head`, `resolve_against_live_head` | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3563` (`reconsider_stale_head`) | rules 1–4, one pass |
| `base_merge_only?` | `apps/arbiter/lib/arbiter/worker/watchdog.ex:3698` (`base_merge_only?`) | rule 3 (same `NetDiff`, generalised) |
| MergeQueue's mirrored latch (M2, M4, M5, M6) | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1346` (`item_reviewed_sha`) | the same `Coverage.decide/3` call |
| M3's unbounded retry | `apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1763` (`try_merge`) | class A's bound + terminal park |
| G16's escalation shapes | `apps/arbiter/lib/arbiter/worker/review_gate.ex:2081` (`escalate_commit_gate`) | one fingerprint predicate, one escalation, two remediation strings |

### 6.2 Stays, unchanged

* **`expected_sha` on `merge/2`** (W7) — the *mechanism* stays: it is atomicity,
  not authorisation, and the coverage model does not replace it. Its **retry
  disposition changes** under class A: `merge_fail_count` becomes a terminal
  bound (park + one escalation at `N = 5`) instead of only a paging threshold.
  P6 owns that change, alongside M3's.
* **The four verdict guards** (G9–G12) — they encode real review-quality rules;
  only their *terminal* behaviour changes (class C).
* **`NetDiff`** — already correct, and the model leans on it harder.
* **PRPatrol's bounds** (P1–P3) — the reference implementation of class F.
* **ReviewPatrol's cap and atomic claim** (R4, R5).
* **C1, the bd-ofql8k worker commit gate** — it guards commit hygiene and
  secrets, not review coverage.
* **`issues.last_reviewed_sha`** — demoted to ReviewPatrol's cursor.

### 6.3 Removal order, and the verified-live rule

Root cause 2 of the investigation is *delete-before-verify*: bd-3x0na3's
children removed the proxy and RefreshProbe before the replacement writer was
confirmed writing, and both were P0/P1 outages. So every removal phase here has
an explicit predecessor that is **proven live**, not merely merged:

1. Write coverage rows (P1) — dual-write, nothing reads them.
2. **Observe**: after a restart, a real ReviewGate approval writes a row whose
   `head_sha` equals the PR head, and a base merge writes a `:mechanical` row.
   Recorded as an AC, not as a hope.
3. Read from coverage behind a flag (P3), with the old guard still computing its
   answer and a log line when the two disagree. **Disagreements are the signal**
   — a week of zero disagreements on non-`:mechanical` paths is the gate for P4.
4. Only then delete the latch machinery (P5), then the MergeQueue mirror (P6).

**Reading P3's counter (bd-b0fqcl / #1649).** Step 3's "a log line when the two
disagree" is not enough on its own — the coordinator's journal-grep habits
break in release mode, where `:debug` is dropped and the journal is rotated.
So shadow mode keeps a **durable** counter as well.
`Arbiter.Reviews.CoverageShadow`
(`apps/arbiter/lib/arbiter/reviews/coverage_shadow.ex:180` (`observe`)) is
called from both merge paths —
`apps/arbiter/lib/arbiter/worker/watchdog.ex:3438` (`observe_coverage`) and
`apps/arbiter/lib/arbiter/workflows/merge_queue.ex:1356`
(`observe_coverage`) — and, per distinct
`{site, mr_ref, head, old->new}` observation, logs one `:warning` line naming
both answers and writes one `Arbiter.Events` row on topic `coverage_shadow`.
`apps/arbiter/lib/arbiter/reviews/coverage_shadow/tally.ex:102` (`snapshot`)
carries the since-boot counts, including the re-polls the event log collapses.

After a restart, the gate for P4 reads as one query against the install's
SQLite file:

```sql
select json_extract(payload, '$.result') as result, count(*)
  from events where topic = 'coverage_shadow' group by result;
```

`agree` ≥ 20 with no `disagree` row is step 3's "week of zero disagreements".
`Arbiter.Reviews.CoverageShadow.report/0` answers the same question from
`iex`, and `GET /events?subscribe=coverage_shadow&since=0` streams the rows.

Two known, *declared* gaps in P3's evidence, both of which P4 must close before
it flips: no `:ancestor?` probe is injected (no adapter exposes one), so rule 2
is unreachable and a forge-lag poll counts as a `covered->unknown` or
`unknown->uncovered` disagreement; and a merge with no review baseline at all
(`ReviewedSha.check(nil, _)` — the `Direct` strategy) counts as
`covered->unknown`. The tally's per-transition breakdown is what keeps those
separable from a real `covered->uncovered` disagreement, which is the one that
would block P4.

**The first gap is closed (P4, bd-df3zlo / #1736).**
`Arbiter.Mergers.Merger`'s optional `ancestor?/3` gives both hosted adapters
an ancestry proof — GitHub reads `compare/{base}...{head}`'s `status`, GitLab
reads `repository/merge_base` — and both merge paths inject it, so rule 2 is
reachable and a forge-lag poll answers `{:unknown, :forge_lagging}` on the
first poll. An adapter with no repo to ask (`Direct`) still supplies no probe,
which leaves rule 2 unreachable for it, deliberately: that is the second gap,
and it is a `Direct`-strategy merge with no MR head to race against rather than
a review that was skipped.

**Reading the gate (P4).** The SQL above counts every row, including the ones a
workspace that has *already* flipped produced — which are no longer evidence
about whether it may flip. `Arbiter.Reviews.CoverageShadow.preflip_gate/0`
(`apps/arbiter/lib/arbiter/reviews/coverage_shadow.ex:307` (`preflip_gate`)) is
the query with that distinction and §4.5's deferral built in. It has an
operator-invocable surface (bd-cy2mmu): `arb preflip-gate` /
`GET /api/coverage_shadow/preflip_gate`, or straight from `iex`:

```
MIX_ENV=prod mix run --no-start -e \
  'IO.inspect(Arbiter.Reviews.CoverageShadow.preflip_gate(), pretty: true)'
```

It answers `%{merges:, agreements:, blocking:, blocking_observations:,
deferred:, deferred_observations:, truncated?:, pass?:, reason:}` where
`:merges` counts only observations the old guard decided, `:blocking` must be
empty, `:truncated?` must be false (the read is capped at 10 000 rows, newest
`seq` first; a gate cannot pass on evidence it knows is partial), `:reason`
names why `:pass?` came out the way it did, and `:deferred` holds the **one**
documented exception #1736's AC3 authorises (`deferred_reasons/0`), listed
observation by observation so it can be eyeballed rather than trusted:

* `covered->uncovered` — the post-approval `fix_pass` class of §4.5, P7's
  ticket. The old guard merged a commit no review covers; `decide/3` refused
  it. Five live observations at the time of the P4 flip (#1702, #1723, #1725,
  #1731, #1735).

Every other disagreement is **blocking**, including one that is benign on
inspection:

* `unknown->covered` — the W2 grace window. The old guard is still waiting out
  "have we seen our own push echoed yet" while the head the PR actually reports
  already has a coverage row, so rule 1 answers on the first poll instead of
  the sixth. That improvement is rule 2's stated point, and W7's `expected_sha`
  still pins the merge to that exact head, so a PR resource lagging a *newer*
  push cannot be merged out from under it — the forge rejects the call. One
  live observation (bd-2jkrqu / #1707). P5 deletes the latch that produces the
  `unknown` half. It is counted as blocking anyway: AC3 defers one class and
  this is not it, and widening a stated acceptance criterion is the
  coordinator's call on the evidence, not the gate's to make for them. An
  operator who reads the observation and agrees it is this shape can flip on
  that judgement; the gate will not do it silently.

**No fix-boundary filter (bd-cy2mmu).** `preflip_gate/0` reads the whole
topic — it does not exclude rows older than some "the bug was fixed here"
timestamp. A gate that silently dropped old rows could hide a live regression
as easily as evidence of an old one, and the function has no reliable source
for "when did fix X land" — that's git history, not the shadow log. The
tradeoff is a real false negative for up to `Arbiter.Events.Retention`'s
window (7 days by default) after any fix that resolves a blocking class: the
pre-fix rows keep `:blocking` non-empty until they age out. `preflip_gate/0`
makes that visible instead of hiding it — every `blocking_observations` /
`deferred_observations` entry carries `:occurred_at`, so an operator can see
directly whether the blocking rows all predate a specific fix and choose to
wait out retention rather than treat the gate's `false` as "still broken".

The live P3 evidence read, immediately before P4 landed: 31 `covered->covered`
and 1 `uncovered->uncovered` agreements, 5 `covered->uncovered`, 3
`unknown(forge_lagging)->uncovered` (vs-2bvq9u !224, vs-5bxd80 !229, bd-3ymdvi
#1709 — the class the `:ancestor?` probe closes, and the reason the gate is
re-run *after* the probe is live) and 1 `unknown->covered`.

---

## 7. Phase table

Each phase is one child ticket. "Restart-and-observe" ACs are mandatory wherever
a phase changes Watchdog/ReviewGate runtime behaviour — this repo's coordinator
is a long-lived server and root cause 1 of the investigation is that nothing
verifies a merged change against it.

| Phase | What | Depends on | P | D | Draft ACs |
|---|---|---|---|---|---|
| **P0** | `Arbiter.Reviews.Coverage` resource + migration + `Coverage.record/1`. Table only; nothing reads it | — | P1 | D2 | Table exists; `record/1` is idempotent on `{mr_ref, head_sha, kind}`; unit tests for all three `kind`s |
| **P1** | Dual-write from every stamping site in §3.3 (ReviewGate, ReviewPatrol, ExternalReview). `last_reviewed_sha` still authoritative | P0 | P1 | D2 | **Restart-and-observe:** after a server restart, one real ReviewGate approval writes exactly one `:reviewed` row whose `head_sha` matches the PR head and whose `net_diff_id` is non-nil; the old stamp still matches |
| **P2** | `Coverage.decide/3` — the six rules — as a pure function over a coverage list + ctx. No call sites | P0 | P1 | D3 | Property tests for rules 1–6; table tests for §4.1–§4.6, one per walkthrough; `{:unknown, :forge_lagging}` requires ancestry, not just inequality |
| **P3** | **Shadow mode.** Watchdog and MergeQueue call `decide/3` alongside the existing guard and log disagreements. Behaviour unchanged | P1, P2 | P1 | D2 | **Restart-and-observe:** disagreement log line appears for a real base-merge PR and names both answers; zero disagreements on the exact-match path over ≥20 merges |
| **P4** ✅ | **Read-path flip** behind `merge.coverage_enabled` (bd-df3zlo / #1736). `decide/3` is authoritative when the flag is on; old guard still shadows. Adds the `:ancestor?` probe both adapters lacked, and W20/M8's bounded wait for `{:unknown, _}` | P3 proven live | P0 | D3 | **Restart-and-observe:** one fix-round PR and one base-merge PR merge on the first eligible poll with no `{:stale_reviewed_sha, …}` and no `{:unreviewed_head, …}` in the journal. Flag stays **off** until `preflip_gate/0` passes |
| **P5** | Delete the Watchdog latch/suspension/memo/grace machinery (§6.1 rows 2–5) | P4 live ≥7 days, zero disagreements | P1 | D3 | `watchdog.ex` loses ≥250 lines; every deleted-guard test either deletes or re-points at `decide/3`; **restart-and-observe** one full approve→merge cycle |
| **P6** | Delete the MergeQueue mirror; queue calls `decide/3`; **bound both unbounded merge-call retries: M3's stale-SHA retry and W7's `merge_fail_count`** become class A's bound + park | P5 | P1 | D2 | A stale-coverage item reaches a terminal parked state within N ticks and escalates exactly once; a Watchdog whose `merge/2` keeps failing parks after 5 consecutive attempts, escalates once, and issues no further merge call (it may keep watching); no class-A row in the registry has an unbounded merge-call path; **restart-and-observe** |
| **P7** ✅ | Post-approval `fix_pass` / conflict-resolver pushes stop suspending the guard; content-equal pushes write `:mechanical`, content-changing ones route to a scoped `S2..S3` re-review (§4.5) (bd-60r6wp / #1738) | P4 | P0 | D3 | A fix-pass commit is never merged without a coverage row; the re-review is delta-scoped; **restart-and-observe** on a real CI-failure PR |
| **P8** | `Arbiter.Reviews.GuardRegistry` + the two conformance tests (§5.4) | — (parallel with P0–P2) | P1 | D2 | Every §2 guard has a row; a new refusal path without a row fails the suite; no row has an infinite bound |
| **P9** ✅ | Apply class C to the ReviewGate terminal paths: `:review_gate_inconclusive` and the exhausted verdict guards park + escalate once instead of failing the run | P8 | P0 | D3 | No ReviewGate outcome sets `Run.status = :failed` on a task whose PR is approved; the 4 chain-B shapes each produce exactly one escalation; **restart-and-observe** |
| **P10** | Apply class E/F audit: bound R2's CI-settle defer; confirm every remaining guard matches its registry row. P9 also hands it the one arm it deliberately left: **G14/C2's genuine REQUEST_CHANGES at the round cap**, which §5.3 would park as class D and P9's AC1 kept failing | P8 | P2 | D2 | Registry conformance test green with zero exemptions |
| **P11** | `arb review cover <task> <sha> --reason` (the `:operator` kind) + `arb review coverage <task>` | P0 | P2 | D1 | **Restart-and-observe:** writing a row for a really-parked PR unblocks its class-A guard on the next poll of the running coordinator |
| **P12** | Demote `issues.last_reviewed_sha` to ReviewPatrol's cursor; remove every merge-path read; docs + moduledocs; re-anchor this doc's citations and §2's line counts against the post-P5/P6 source | P6, P7 | P2 | D1 | No merge path references the column; `ReviewedSha` module deleted; **restart-and-observe:** after a restart, one full approve→merge cycle completes with no `ReviewedSha` or `last_reviewed_sha` read on the merge path in the journal; `ReviewCoverageDesignTest` green |

P4, P6, P7 and P9 are P0 because they are the ones that stop money burning.
P5 is deliberately *not* P0: deleting is the last thing that happens, after the
new path is proven live.

---

## 8. Non-goals

* **Fixing the verdict parser.** Chain B's parsing defects are real and are not
  addressed here; §4.6 only changes what a parse failure costs. bd-3hb4ih stays
  a parser ticket.
* **Giving the reviewer a worktree checkout** (bd-199giy, merged as #1350).
  The internal ReviewGate reviewer already works from a worktree checkout.
  Recommendation 4 of the investigation, a separate ticket, and orthogonal:
  it changes review *quality*, not review *bookkeeping*.
* **A generic circuit breaker for auto-filing paths.** Recommendation 3. Class F
  in §5.3 states the policy for the guards in this inventory; the generic
  circuit breaker (bd-5jr49o) merged as #1638. (ReviewPatrol-specific breakers
  bd-1atwts and bd-wtvu9r merged as #1548 and #1572.)
* **Changing the ReviewGate's round budget, model tier or prompts.**
* **Webhook-driven merge detection.** Still the right upgrade
  (`apps/arbiter/lib/arbiter/worker/watchdog.ex:1315` (`effective_outcome`)
  already encapsulates classification), still out of scope.

---

## Appendix A — how this inventory was produced, and how to re-verify it

Read-only. No code under `apps/*/lib` was changed by this PR.

* Guards were enumerated by reading every refusal path in
  `worker/review_gate.ex`, `worker/watchdog.ex`, `workflows/merge_queue.ex`,
  `worker.ex`'s commit gate and fix-round dispatcher, and
  `workflows/review_patrol.ex` / `workflows/pr_patrol.ex`, following each
  `bd-…` reference in the source comments back to its originating incident.
* "Patches" counts the distinct `bd-…` tasks named in the comments governing
  that guard, which is a lower bound on how many times it has been revised.
* Line counts, commit counts, run counts and dollar figures are quoted from
  bd-bc0n3k's investigation (`admiral:notes/2026-09-13-follow-up-rate-investigation.md`
  §3.1–3.4), which read them from `~/dev/arbiter_dev.sqlite3` in `mode=ro`.
* `apps/arbiter/test/arbiter/review_coverage_design_test.exs` re-checks every
  anchored `` `path:line` (`symbol`) `` citation in this document on every test
  run. If it fails, the inventory has drifted — re-anchor it rather than
  loosening the test.
