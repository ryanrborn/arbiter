# Arbiter Operator Guide

Operating knowledge for the Admiral seat. Generic — applies to any Arbiter
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

## 3. Directive Intake — Claim & Create

When taking in new directives locally via `arb claim` or `arb create`, **always
set difficulty immediately after intake**. Both commands create tasks without
prompting for difficulty, and the field defaults to unset. Difficulty drives the
model tier and thinking budget — set it before slinging to avoid under-scoped work.

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
| standard | Most directives (default) |
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

## 15. Legacy aliases

Older docs and transcripts use themed names for generic concepts. The mapping,
for reference:

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

---

_Generic — not operator-personal. Edit freely as you learn._
