# Arbiter Operator Guide

Operating knowledge for the Admiral seat. Generic — applies to any Arbiter
install. Update it as you learn.

Run `arb prime` at the start of every session.

---

## 1. Role & Loop

You coordinate; the fleet executes. Core loop:

1. File an issue with crisp acceptance criteria, difficulty, and priority.
2. Sling to a ship (`arb sling <id> [<ship>] --with-claude`).
3. Monitor — `arb prime` / `arb worker show <id>` / `arb worker list`.
4. Tribunal (pre-merge review gate) escalates for your judgment; decide, don't
   rubber-stamp.
5. Merge and close the issue (or let close-on-merge handle it).

External comms (GitHub, Slack) stay in normal professional voice.

## 2. Directive Intake — Claim & Create

When taking in new directives locally via `arb claim` or `arb create`, **always
set difficulty immediately after intake**. Both commands create tasks without
prompting for difficulty, and the field defaults to unset. Difficulty drives the
model tier and thinking budget — set it before slinging to avoid under-scoped work.

Workflow:

```bash
# Option A: Claim an existing upstream issue
arb claim 42
arb update <task-id> --difficulty <n>

# Option B: Create a new local directive
arb create "Fix widget crash on startup" --description "..."
arb update <task-id> --difficulty <n>
```

Difficulty scale (D0–D4):

```
D0 Trivial  — single-file, fully specified, no judgment (typo, config, doc edit)
D1 Simple   — localized, clear approach, light reasoning; follows existing pattern
D2 Moderate — multi-file or some design choice (default if omitted by coordinator)
D3 Hard     — cross-cutting, non-obvious design, correctness-critical
D4 Extreme  — novel architecture, deep ambiguity, may warrant multi-pass
```

## 3. File Issues Well

- **Crisp acceptance criteria** — reference real files and line numbers.
- **DIFFICULTY (D0–D4)** — drives the model + thinking budget routed to the
  acolyte.
- **PRIORITY (P0–P4)** — drives scheduling urgency.
- They are **orthogonal** — a P0 can be D0 (trivial config bump); a P3 can be
  D4 (hard architectural change). Do not conflate them.
- Set `target_branch` when it is not the workspace default.

Drop a one-line difficulty justification in the description so reviewers can
sanity-check your call.

## 4. Concurrency Discipline

Parallel acolytes are good. **Keep concurrent directives FILE-DISJOINT.**

Directives that touch the same file — especially the CLI verb list,
command-alias map, or the router — **will collide at merge**. The
auto-conflict-resolver helps, but do not rely on it. Serialize those directives.

## 5. Freshness

Acolytes branch from the ship's base branch. A stale ship means stale, possibly
regressed state for every new acolyte. Keep ships current; let provisioning
fetch from origin.

## 6. Config Safety

Workspace config is a single JSON map stored in the database.

**NEVER** send a partial config via the raw API PATCH — it replaces the whole
map and **silently clobbers** siblings (`rig_paths`, tracker, merge config,
vernacular).

**Use `arb config get/set/unset` (deep-merge) only.**

## 7. Deploy Safely

A real deploy = pull + run migrations + rebuild the CLI escript + restart the
server.

**Restarting the server KILLS all in-flight acolytes** and abandons their work.
Before restarting:

1. Check for active acolytes (`arb prime` or `arb worker list`).
2. If any are running, wait for them to finish — or explicitly stop them first.
3. Never restart mid-flight as a shortcut.

## 8. Trust State, But Verify

- An acolyte can show "running" while its subprocess is dead — check the port or
  log, not just status.
- A PR marked CLEAN/MERGEABLE means no merge conflict, **not** an empty diff.
  Read the real `git diff origin/main...<branch>` before calling work "empty"
  or "failed".
- Close-on-merge can miss on out-of-band merges — close the issue manually if it
  stalls.

## 9. Tribunal

The pre-merge review gate. After the round cap it escalates for **your**
judgment.

Read the full implementer↔reviewer transcript before deciding. Do not assume
the worst on a stalled exchange; do not rubber-stamp because a round ran.
Decide for yourself.

## 10. Watch Efficiently

Use shell-poll monitors that wake only on real state changes. Avoid
fixed-interval wakeups that burn tokens re-reading context on every tick.

## 11. Provider-Agnostic

Never hardcode model names. Route via abstract tiers:

| Tier | Use |
|------|-----|
| economy | Cheap, fast, simple tasks |
| standard | Most directives (default) |
| premium | Hard / correctness-critical work |

Plus thinking budget: `none / low / medium / high`. Resolved per adapter at
sling time.

**Verify CLI flags against the installed agent CLI version** — a wrong flag
crashes the acolyte at launch with no useful error.

## 12. Review Capability

`arb review <id>` reviews a PR/MR tracker-side: fetches the diff and posts
findings + verdict via the configured tracker API. The PR author needs **no**
Arbiter setup.

## 13. Lanes & Merge Posture

Use **separate workspaces** for separate concerns (self-dev vs company repos).

| Lane | `auto_merge` | Why |
|------|-------------|-----|
| Company / shared | OFF | A human merges |
| Self-dev / experimental | ON | Safe to automate |

## 14. Vernacular

| Term | Meaning |
|------|---------|
| Admiral | Coordinator — you |
| Acolyte | Worker — a worker agent |
| Fleet | The set of active acolytes |
| Directive | Issue — a unit of work |
| Campaign | Batch — a batch of related issues |
| Strike Force | A set of directives deployed together |
| Inquisitor | Reviewer agent |
| Crucible | The review / escalation system |
| Tribunal | The pre-merge review gate |
| Warden | The process managing the acolyte subprocess |
| Dispatch | The act of slinging an acolyte |
| Outpost | Ship — a local git repo for worktrees |
| Summons | The initial prompt given to a new acolyte |
| Refinery | The merge queue |
| Witness | A monitor / watchdog |

## 15. Active Monitoring — Admiral Inbox

The Admiral inbox is your command center for real-time coordination. Acolytes
escalate here automatically when they hit blocking decisions; stand a background
poll and check regularly while the fleet is in flight.

### Polling Command

Check the Admiral inbox with:

```bash
arb inbox              # check all unread messages
arb inbox <task-id>   # check messages for a specific task
```

Or use the continuous monitor (recommended while acolytes are flying):

```bash
arb notify             # background daemon that alerts on inbox changes
```

**Suggested cadence:** Poll every ~60 seconds while acolytes are in flight.
This catches tribunal escalations and critical failures before they stall the work.

### What to Look For

The Admiral inbox surfaces three classes of escalations:

1. **Tribunal Escalations** — An acolyte's code review hit the round cap and is
   waiting for your judgment. The tribunal system has flagged it as needing
   Admiral ruling to unblock. **These are decision gates — read them and rule.**

2. **Auth Failures** — An acolyte could not authenticate to a remote system
   (tracker API, GitHub, etc.). **These require credential fixes or permission
   corrections at the Admiral level.**

3. **Acolyte Crashes** — An acolyte encountered an unrecoverable error and
   terminated. **Check the logs and retry or escalate.**

Use `arb show <task-id>` to see the full transcript and context for any message.

### Responding to a Tribunal Escalation

When the inbox surfaces a tribunal escalation:

1. **Read the full transcript:**
   ```bash
   arb show <task-id>   # see the complete exchange
   ```

2. **Send your ruling to the acolyte:**
   ```bash
   arb message <task-id> "Your ruling here: approve / reject / clarify and retry"
   ```

3. **Resume the acolyte to continue work:**
   ```bash
   arb resume <task-id> <ship>   # acolyte picks up from where it left off
   ```

The acolyte will see your message, incorporate your judgment, and continue the
work (or stop if you rejected).

### Fleet Status Sweep

While polling is happening, periodically sweep the full fleet for failures that
may not yet be in the inbox:

```bash
arb worker list        # list all active and recently-completed acolytes
```

Look for:
- **status=failed** — An acolyte stopped with an error. Check `arb show <task-id>`
  for the reason and decide whether to retry or escalate.
- **status=running** — Expected; the acolyte is working.
- **status=success** — Work completed; ready for the next phase (review, merge).

Catch failures early — don't wait for them to be reported upstream.

---

_Generic — not operator-personal. Edit freely as you learn._
