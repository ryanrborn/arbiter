# Rework Spend Investigation (chore #524)

**Date:** 2026-06-27  
**Scope:** All usage_events in arbiter_dev.sqlite3 (387 events, through 2026-06-27)

## Summary

Rework tasks (tasks with >1 `:work` usage row — i.e., re-slung at least once) account for **$272.76 of $441.81 in total work spend = 61.7%**. The dominant cause is server restarts killing in-flight workers, not actual task quality failures.

## Root Causes (by spend)

| Cause | Runs | Spend | % of Linked Work |
|---|---|---|---|
| **Server restart killed worker** | 190 | $228.19 | 64.9% |
| Worker exited w/o `arb done` | 25 | $40.26 | 11.4% |
| Review gate rejection | 9 | $26.09 | 7.4% |
| Other failure | 14 | $13.26 | 3.8% |
| Success (first-pass) | 96 | $40.11 | 11.4% |

### 1. Server Restarts (64.9% of linked work spend = ~$228)

55.7% of all worker runs fail with `"server restarted"`. When the Elixir server restarts, every active worker gets killed mid-session and its task is re-slung. The re-slung task starts from scratch with no context from the prior session — the prior session's spend is entirely wasted.

Heavy restart days: Jun 17 (29 kills), Jun 18 (46 kills), Jun 19 (28 kills), Jun 22 (23 kills). These correlate with active development of the server itself.

**Fix directions:**
- Resume-aware re-dispatch: pass the prior session's worktree state and key outputs to the re-slung agent so it doesn't redo completed work.
- Graceful drain before restart: give in-flight workers a signal to finish or checkpoint before the server goes down. `Process.flag(:trap_exit, true)` + drain window.
- Reduce restart frequency: the server is often restarting because it's being actively developed. A hot-code-reload or a dedicated dev/prod split would help.

### 2. Workers Exiting Without `arb done` (11.4% = ~$40)

13 runs (25 usage events) exited with code 0 but never emitted `arb done`. The gate re-slungs the task, burning the prior session's spend. Common patterns seen:
- `bd-guegdl`: $21.74 lost on a single session that finished work but didn't emit the sentinel
- `bd-5lc99r`: 5 of its 12 sessions were "no arb done" failures

**Fix directions:**
- Make `arb done` easier to emit correctly — current prompt uses "print on its own line" but context window compression or model confusion causes misses.
- Add a pre-exit check in the worker that detects `arb done` absence before marking a clean exit as a failure (instead of re-slinging immediately, warn/pause).
- The commit-gate check (this task's trigger) is a good backstop — extend it to also catch the no-sentinel case before the full re-sling cycle.

### 3. Review Gate Rejections (7.4% = ~$26)

9 runs were rejected by the review gate and re-slung. This is *intentional* rework — review works as designed. However, $26 on 9 rejections is meaningful:

- Some rejections may be from overly strict reviewers.
- Tasks with multiple review rejections (`bd-5lc99r` had 7 total runs, multiple rejections) suggest the review feedback isn't being incorporated well on re-dispatch.

**Fix directions:**
- Pass the review rejection reason explicitly to the re-slung worker prompt so it can focus on the feedback.
- Consider a "reviewer memo" that survives re-dispatch and is prepended to the next worker's context.

## Worst Offenders

| Task | Sessions | Spend | Cause |
|---|---|---|---|
| bd-5lc99r (feat: task issue type) | 12 | $22.40 | Mixed: crash, no-arb-done, auth failure |
| bd-awwtf3 (feat: quota bars UI) | 13 | $6.61 | Mostly no-arb-done |
| bd-guegdl (feat: sling provider) | 3 | $23.47 | $21.74 wasted on one no-arb-done |
| bd-dem49g (feat: MCP phase 1) | 4 | $22.56 | Server restart kills |
| bd-bzvl67 (feat: ash_cloak) | 2 | $20.35 | Server restart |

## Highest-Leverage Actions

1. **Graceful drain before server restart** — addresses 64.9% of wasted spend. Even a 30-second drain window to let workers emit `arb done` would recover the majority.
2. **Pass prior context on re-dispatch** — when re-slinging after a restart, include a note: "A prior session ran and may have partially completed this task. Check the worktree." Workers often redo completed work.
3. **Fix no-arb-done rate** — 13 clean exits without the sentinel burning $40. Review prompt enforcement.
4. **Cap re-sling count** — tasks with >3 re-slings should escalate to human review rather than continue burning.
