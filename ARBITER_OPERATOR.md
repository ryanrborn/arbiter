# Arbiter Operator Guide

Operating knowledge for the coordinator seat. Generic — applies to any Arbiter
install. Update it as you learn.

Run `arb prime` at the start of every session.

---

## 1. Role & Loop

You coordinate; the workers execute. Core loop:

1. File an issue with crisp acceptance criteria, difficulty, and priority.
2. Dispatch to a repo (`arb dispatch <id> [<repo>]`).
3. Monitor — `arb prime` / `arb worker show <id>` / `arb worker list`.
4. Review gate (pre-merge) escalates for your judgment; decide, don't
   rubber-stamp.
5. Merge and close the issue (or let close-on-merge handle it).

External comms (GitHub, Slack) stay in normal professional voice.

## 2. Operating Pitfalls — Quick Reference

The six most-burned-by operating pitfalls. Check these first:

- [ ] **Concurrency** — keep concurrent tasks FILE-DISJOINT. Tasks that touch the same file (especially CLI verb list, command-alias map, or router) **will collide at merge**. The auto-conflict-resolver helps, but do not rely on it. Serialize those tasks.
- [ ] **Config** — use `arb config get/set/unset` only. **Never** send partial config via raw API PATCH — it replaces the whole map and **silently clobbers** siblings (`rig_paths`, tracker, merge config, vernacular).
- [ ] **Deploy** — before restarting the server, check for active workers (`arb prime` or `arb worker list`). **Restarting the server KILLS all in-flight workers and abandons their work.**
- [ ] **Freshness** — keep repos current. Workers branch from the repo's base branch. A stale repo means stale, possibly regressed state for every new worker.
- [ ] **Verify** — a worker can show "running" while its subprocess is dead. **Check the port/log, not just status.** A PR marked CLEAN/MERGEABLE means no merge conflict, **not** an empty diff.
- [ ] **ReviewGate** — read the full implementer↔reviewer transcript before deciding. Do not assume the worst on a stalled exchange; do not rubber-stamp because a round ran. **Decide for yourself.**

## 3. Issue Intake — Claim & Create

When taking in new issues locally via `arb claim` or `arb create`, **always
set difficulty immediately after intake**. Both commands create tasks without
prompting for difficulty, and the field defaults to unset. Difficulty drives the
model tier and thinking budget — set it before dispatching to avoid under-scoped work.

Workflow:

```bash
# Option A: Claim an existing upstream issue
arb claim 42
arb update <task-id> --difficulty <n>

# Option B: Create a new local task
arb create "Fix widget crash on startup" --description "..."
arb update <task-id> --difficulty <n>
```

Difficulty scale (D0–D4):

```
D0 Trivial  — single-file, fully specified, no judgment (typo, config, doc edit)
D1 Simple   — localized, clear approach, light reasoning; follows existing pattern
D2 Moderate — multi-file or some design choice (default if omitted)
D3 Hard     — cross-cutting, non-obvious design, correctness-critical
D4 Extreme  — novel architecture, deep ambiguity, may warrant multi-pass
```

## 4. File Issues Well

- **Crisp acceptance criteria** — reference real files and line numbers.
- **DIFFICULTY (D0–D4)** — drives the model + thinking budget routed to the
  worker.
- **PRIORITY (P0–P4)** — drives scheduling urgency.
- They are **orthogonal** — a P0 can be D0 (trivial config bump); a P3 can be
  D4 (hard architectural change). Do not conflate them.
- Set `target_branch` when it is not the workspace default.

Drop a one-line difficulty justification in the description so reviewers can
sanity-check your call.

## 5. Concurrency Discipline

Parallel workers are good. **Keep concurrent tasks FILE-DISJOINT.**

Tasks that touch the same file — especially the CLI verb list,
command-alias map, or the router — **will collide at merge**. The
auto-conflict-resolver helps, but do not rely on it. Serialize those tasks.

## 6. Freshness

Workers branch from the repo's base branch. A stale repo means stale, possibly
regressed state for every new worker. Keep repos current; let provisioning
fetch from origin.

That auto-fetch (`Worktree.fetch_origin/2`) only refreshes the
`origin/<base>` *ref* inside a repo's primary checkout (the shared directory
in `repo_paths`/`rig_paths` — not a worker's isolated worktree). It never
touches that checkout's own local branch, HEAD, index, or working tree — so
`git log`/`git status` run directly in the primary checkout (by you, or by a
`task`-type worker reading it for context) can still show a branch that's
weeks behind `origin/main`, even though every dispatch has kept the ref
fresh. This bit a real audit: a worker read a checkout ~1 month stale and
confidently reported already-shipped work as unmerged (bd-bqqnin).

Opt a repo in to closing that gap with `config["merge"]["auto_sync_primary"]
= true` (`arb config set merge.auto_sync_primary true`, default `false`).
When set, every merge to that repo's default branch fast-forwards the
primary checkout's local branch to the new `origin/<base>` — but *only* as a
zero-risk fast-forward: the checkout must already be on the default branch,
clean (no uncommitted changes), and a strict ancestor of the new tip. Any
other state (dirty tree, checked out elsewhere, diverged history — i.e. a
human mid-work in that checkout) is skipped silently (logged, not errored);
it never resets, stashes, or switches branches out from under someone. Still
worth an explicit `git pull` if you're about to trust a primary checkout for
something high-stakes and aren't certain `auto_sync_primary` is on for that
repo.

## 7. Config Safety

Workspace config is a single JSON map stored in the database.

**NEVER** send a partial config via the raw API PATCH — it replaces the whole
map and **silently clobbers** siblings (`rig_paths`, tracker, merge config,
vernacular).

**Use `arb config get/set/unset` (deep-merge) only.**

## 8. Deploy Safely

A real deploy = pull + run migrations + rebuild the CLI escript + restart the
server.

**Restarting the server KILLS all in-flight workers** and abandons their work.
Before restarting:

1. Check for active workers (`arb prime` or `arb worker list`).
2. If any are running, wait for them to finish — or explicitly stop them first.
3. Never restart mid-flight as a shortcut.

### Post-deploy: confirm patrols are lazy (bd-7tr11p acceptance gate)

Patrols exist only while a repo has watched work (an open review engagement or a
fleet-authored open PR). A restart with no open work must produce **no** patrol
sweep at all. Verify this after any deploy that touches patrol lifecycle, with
the fleet idle (0 workers, no open engagements, no fleet-authored open PRs):

    scripts/measure_patrol_idle_rate_limit.sh        # samples >=5 min, asserts near-zero

`gh api rate_limit` is exempt, so the sampler doesn't perturb what it measures —
any rise in `.resources.core.used` over the window is background traffic. **Pass**
= near zero. **Fail** = something is still polling; grep the journal for the
per-repo patrol **start**/**stop** lines to see which repo and why. Compare a
fail against the pre-#1036 signature: a ~30-call burst ~1/min (~2,200/hr idle).

This is the live measurement `bd-4brb2j` asked for and could not satisfy; it can
only run against a real deployment, not from a worker worktree. Record the
samples on the PR / task.

## 9. Trust State, But Verify

- A worker can show "running" while its subprocess is dead — check the port or
  log, not just status.
- A PR marked CLEAN/MERGEABLE means no merge conflict, **not** an empty diff.
  Read the real `git diff origin/main...<branch>` before calling work "empty"
  or "failed".
- Close-on-merge can miss on out-of-band merges — close the issue manually if it
  stalls.

## 10. Review Gate

The pre-merge review gate. After the round cap it escalates for **your**
judgment.

Read the full implementer↔reviewer transcript before deciding. Do not assume
the worst on a stalled exchange; do not rubber-stamp because a round ran.
Decide for yourself.

## 11. Watch Efficiently

Use shell-poll monitors that wake only on real state changes. Avoid
fixed-interval wakeups that burn tokens re-reading context on every tick.

## 12. Provider-Agnostic

Never hardcode model names. Route via abstract tiers:

| Tier | Use |
|------|-----|
| economy | Cheap, fast, simple tasks |
| standard | Most issues (default) |
| premium | Hard / correctness-critical work |

Plus thinking budget: `none / low / medium / high`. Resolved per adapter at
dispatch time.

**Verify CLI flags against the installed agent CLI version** — a wrong flag
crashes the worker at launch with no useful error.

## 13. Review Capability

`arb review <id>` reviews the PR/MR linked to an Arbiter task: fetches the diff
and posts findings + verdict. The PR author needs **no** Arbiter setup.

`arb review --pr <url|number> [--repo <checkout>] [--workspace <ref>]` reviews an
**external / non-arbiter PR** — one the fleet never opened (a coworker's PR) —
with no task and no branch. It constructs a merge-request ref through the
workspace's **MR provider** (the `config["merge"]["strategy"]` adapter —
github/gitlab, *not* the issue tracker, so a Jira-tracked workspace still reviews
its GitHub PRs) and runs the CodeReview adapter workflow: read diff → post inline
findings → submit a verdict, all on the PR. `--pr` accepts a forge URL, an
`owner/repo#N` slug, or a bare number (pass `--repo` so a number resolves to
owner/repo via the checkout's `origin` remote). The same is exposed over MCP as
`worker_review` with a `pr` argument.

## 14. Lanes & Merge Posture

Use **separate workspaces** for separate concerns (self-dev vs company repos).

| Lane | `auto_merge` | Why |
|------|-------------|-----|
| Company / shared | OFF | A human merges |
| Self-dev / experimental | ON | Safe to automate |

## 15. Legacy terminology reference

Older docs and transcripts use themed names for generic concepts. The mapping,
for reference (these terms are retired; use the current terms listed below):

| Legacy term | Current term |
|-------------|--------------|
| Acolyte / Polecat | Worker |
| Admiral | Coordinator (you) |
| Tribunal | Review gate |
| Warden | Watchdog |
| Refinery | Merge queue |
| Inquisitor | Reviewer |
| Crucible | Review / escalation system |
| Witness | Monitor |
| Rig / Outpost | Repo / worktree |
| Sling | Dispatch |
| Campaign / Strike Force | Batch |
| Fleet | The set of active workers |
| Directive | Task / issue |
| Summons | Work prompt |

## 16. Active Monitoring — Coordinator Inbox

The coordinator inbox is your command center for real-time coordination. Workers
escalate here automatically when they hit blocking decisions; stand a background
poll and check regularly while workers are in flight.

### Polling Command

Check the coordinator inbox with:

```bash
arb message inbox              # check all unread messages
arb message inbox <task-id>   # check messages for a specific task
```

Or use the continuous monitor (recommended while workers are in flight):

```bash
arb notify             # background daemon that alerts on inbox changes
```

**Suggested cadence:** Poll every ~60 seconds while workers are in flight.
This catches review gate escalations and critical failures before they stall work.

### What to Look For

The coordinator inbox surfaces three classes of escalations:

1. **Review Gate Escalations** — A worker's code review hit the round cap and is
   waiting for your judgment. The review gate has flagged it as needing
   coordinator ruling to unblock. **These are decision gates — read them and rule.**

2. **Auth Failures** — A worker could not authenticate to a remote system
   (tracker API, GitHub, etc.). **These require credential fixes or permission
   corrections at the coordinator level.**

3. **Worker Crashes** — A worker encountered an unrecoverable error and
   terminated. **Check the logs and retry or escalate.**

Use `arb show <task-id>` to see the full transcript and context for any message.

### Responding to a Review Gate Escalation

When the inbox surfaces a review gate escalation:

1. **Read the full transcript:**
   ```bash
   arb show <task-id>   # see the complete exchange
   ```

2. **Send your ruling to the worker:**
   ```bash
   arb message <task-id> "Your ruling here: approve / reject / clarify and retry"
   ```

3. **Resume the worker to continue:**
   ```bash
   arb resume <task-id> <repo>   # worker picks up from where it left off
   ```

The worker will see your message, incorporate your judgment, and continue the
work (or stop if you rejected).

### Worker Status Sweep

While polling is happening, periodically sweep all workers for failures that
may not yet be in the inbox:

```bash
arb worker list        # list all active and recently-completed workers
```

Look for:
- **status=failed** — A worker stopped with an error. Check `arb show <task-id>`
  for the reason and decide whether to retry or escalate.
- **status=running** — Expected; the worker is working.
- **status=success** — Work completed; ready for the next phase (review, merge).

Catch failures early — don't wait for them to be reported upstream.

## 17. Loop analysis (weekly)

Periodically review how the loop itself is performing:

    arb loop analyze --since 7d          # or: mix arbiter.loop.analyze --since 7d

This is the **manual, read-only** Stage 1 loop-analysis pass. It segments
failures operational-vs-agent-quality by allowlist (so our own deploy restarts
don't dominate), corroborates each `failure_reason` against the transcript
(the label lies — context-exhaustion hides behind "rate-limited"/"crashed"
labels), and emits a report with a suggested destination per finding (skill /
repo `CLAUDE.md` / per-task override). It **writes nothing** but the report and
one cost-ledger row — you read it and decide. Evidence bar for any fleet-wide
change: ≥ 3 incidents across ≥ 2 tasks; a single incident is a per-task
override. Full guide: `docs/loop-review.md`.

---

_Generic — not operator-personal. Edit freely as you learn._
