# Review-Worker Lifecycle — Design Document

**Status:** shipped (updated to reflect ReviewPatrol A–H, bd-bdb1ix)
**Last updated:** 2026-07-01
**Epic:** ReviewPatrol (bd-blbggh)

---

## Overview

When Arbiter reviews a colleague's PR (`arb review --pr <url>`), it creates a
**review engagement**: an `Issue` with `review_only: true` and `source_pr` set.
Unlike normal implementation tasks, review engagements have a long lifecycle
that does not end after the first verdict. **ReviewPatrol** owns that lifecycle
from creation to the PR's merge or close.

---

## Engagement Anatomy

A review engagement is an `Issue` record with:

| Field | Meaning |
|---|---|
| `review_only` | `true` — hard boundary keeping SyncTracker from writing the upstream ticket |
| `source_pr` | The PR ref (e.g. `"42"` for the GitHub PR number) |
| `review_automation` | `:auto` or `:flag` — controls re-review and reply behaviour |
| `last_reviewed_sha` | The last commit SHA we reviewed; nil on first sighting |
| `last_reviewed_at` | When the last re-review or first review fired |
| `posted_findings` | JSON array of `{file, line, message, severity}` — the findings we posted |
| `last_seen_comment_id` | High-watermark comment ID for author-reply dedup |

---

## The Invariant

> **ReviewPatrol may only dispatch `review_only` sub-runs. It must NEVER touch
> the upstream tracker issue.**

`SyncTracker` (the after-action hook on status-changing actions) short-circuits
immediately when `issue.review_only == true`, regardless of tracker type or
tracker ref. Terminating a review engagement therefore fires **zero** tracker
writes, even if the engagement carries a Jira `tracker_ref` for an issue owned
by a colleague.

---

## Lifecycle Phases

### 1. Engagement creation

`arb review --pr <url>` (or the `worker_review` MCP tool) calls
`Arbiter.Workflows.CodeReview` in `:adapter` mode, posts findings and a
verdict, then creates the review engagement via `Arbiter.Worker.Dispatch`. The
task is marked `review_only: true`; the `review_automation` policy is inherited
from the workspace config (`auto_authors` list) or the caller's explicit flag.

### 2. First-sighting SHA record (ReviewPatrol, first tick)

When ReviewPatrol first sees the engagement (`last_reviewed_sha` is nil), it
calls `adapter.get(source_pr)`. If the PR is open and has a head SHA, it stores
that SHA as `last_reviewed_sha`. No review is dispatched here — the initial
review already ran at creation time.

### 3. New-commit re-review (ReviewPatrol, subsequent ticks — task D)

On each tick, if `head_sha` advanced past `last_reviewed_sha`, ReviewPatrol
considers a new-commit re-review. A stack of spam guards runs in order:

1. **CI settle gate** — the PR's pipeline must not be in `[:running, :pending]`.
   If CI is still in flight, the tick defers and tries again on the next cycle.
2. **Debounce** — at most one re-review per configurable window (default: 5 min;
   configurable via `config["review_patrol"]["debounce_ms"]` or the
   `:review_patrol_debounce_ms` app env). A burst of pushes yields one re-review.
3. **Relevance gate** — the new diff (`last_reviewed_sha..head_sha`) must touch a
   file that appears in `posted_findings`. A push to unrelated files is silently
   skipped; the cursor does NOT advance (so a later relevant push is still caught).
4. **Unchanged-finding de-dupe** — findings whose `{file, line, message}` we
   already posted are filtered out before any comments land on the PR.

On a passing re-review, ReviewPatrol:
- Posts inline comments + a verdict (via `CodeReview` in `:adapter` mode through
  the `review_agent` model slot — a cheaper tier than the initial review).
- Appends new findings to `posted_findings`.
- Advances `last_reviewed_sha` to `head_sha` and stamps `last_reviewed_at`.

If automation mode is `:flag`, no review is posted. Instead, ReviewPatrol sends
a mailbox flag to the engagement (kind: `:flag`) and still advances the cursor so
the same commits are not re-flagged on the next tick.

### 4. Author-reply handling (ReviewPatrol, subsequent ticks — task G)

When the head has NOT advanced (no new commits this tick), ReviewPatrol checks
for author replies on the review threads we own. It uses the adapter's
`list_open_review_threads/1` + `filter_to_our_threads/2` (GitHub implementation:
a GraphQL query filtered by our login configured in
`config["review_patrol"]["our_login"]`). Only comments newer than
`last_seen_comment_id` authored by the PR author are handled; comments from other
reviewers and from the fleet itself are ignored.

The automation mode governs the response:

- **`:auto`** — dispatches `Arbiter.Workflows.ReviewReply` (task F) to compose
  and post a threaded reply. The reply is anchored to the specific comment in the
  original review thread, not a new PR comment.
- **`:flag`** — posts NOTHING to the PR. Raises exactly one `:escalation` message
  addressed to `to_ref: "admiral"` with the PR link, thread path, and a 280-char
  body snippet. A human decides whether to reply or trigger a re-review.

Either way, `last_seen_comment_id` is advanced past the highest comment id in the
handled batch, so the same reply is processed (or escalated) exactly once, never
per-tick.

### 5. Merge / close termination (ReviewPatrol — task C)

When `adapter.get(source_pr)` returns `status: :merged` or `status: :closed`,
ReviewPatrol closes the engagement via the `:close` action. Because the
engagement is `review_only`, `SyncTracker` no-ops — zero tracker writes.

**Idempotency**: the open-engagements query filters `status != :closed`, so a
closed engagement is never selected again. Re-ticking after termination is a
pure no-op.

---

## Spam Guards Summary

```
tick
 └─ head advanced?
      ├─ yes  →  CI settled?  (no → defer)
      │           debounced?  (yes → skip)
      │           relevant?   (no → skip)
      │           automation?
      │             :auto → CodeReview sub-run (new-diff-only, dedupe)
      │             :flag → send mailbox flag, advance cursor
      └─ no   →  new author replies on our threads?
                   none → nil (nothing to do this tick)
                   some →
                     automation?
                       :auto → ReviewReply sub-run (in-thread)
                       :flag → one :escalation to "admiral", advance cursor
```

---

## Supervisor & Registration

ReviewPatrol is started per `(workspace_id, repo)` pair by
`Arbiter.Workflows.ReviewPatrolSupervisor` (a `DynamicSupervisor`). It uses its
own registry (`Arbiter.Workflows.ReviewPatrolRegistry`) — separate from
PRPatrol's — so the two patrol families never share a namespace.

Auto-start at boot is gated by `:arbiter, :auto_start_refineries` (same flag as
PRPatrol and MergeQueue). Auto-start is disabled in `test`, enabled everywhere
else.

Single-repo workspaces register under `workspace_id`; multi-repo workspaces
register one patrol per repo under `"workspace_id:owner/repo"`.

---

## Operator Configuration

### Enabling ReviewPatrol for a workspace

ReviewPatrol starts automatically at boot for any workspace whose merge strategy
is `"github"` and that has a resolvable repo (either `merge.config.repo` set, or
a `rig_paths` map whose rigs have a GitHub `origin` remote). No separate
configuration key is required.

To set the patrol interval (default: 60 s):

```bash
arb config set review_patrol.interval_ms 120000   # 2 minutes
```

Requires a server restart to take effect (the interval is read at GenServer init;
changing it live requires `Arbiter.Workflows.ReviewPatrolSupervisor.start_patrol/2`
with the new opts).

### Configuring the fleet login (author-reply handling)

Author-reply detection uses the fleet's own GitHub login to identify threads we
participated in. Set it via:

```bash
arb config set review_patrol.our_login "your-bot-account"
```

Without this, author-reply handling is conservatively skipped.

### Configuring automation mode per workspace

`review_automation` controls the default stance for new engagements in the
workspace. It is set at engagement-dispatch time based on whether the PR author
is in the workspace's `auto_authors` list:

```bash
# Authors who get automatic re-reviews and threaded replies
arb config set review_patrol.auto_authors '["alice","bob"]'
```

Authors not in the list default to `:flag` mode (coordinator escalation only,
no automatic posting).

To override the debounce window (default 5 min):

```bash
arb config set review_patrol.debounce_ms 300000   # 5 minutes (default)
```

### How flag-mode escalations surface

When `review_automation` is `:flag`, ReviewPatrol never posts to the PR. Instead:

- **New relevant commits** → a mailbox message (kind: `:flag`, `to_ref`:
  engagement id) appears in the coordinator mailbox under `arb inbox`.
  It names the PR, the new head SHA, and notes that no re-review was posted.
- **Author reply on our thread** → a mailbox message (kind: `:escalation`,
  `to_ref`: `"admiral"`) lands in the coordinator inbox. It includes the PR link,
  the file path of the thread, and a 280-char snippet of the author's reply.

Both message types are deduplicated: a given push or reply fires at most one
flag/escalation and the cursor advances so subsequent ticks are no-ops.

To read escalations:

```bash
arb inbox                     # all unread messages, including escalations
arb message inbox <task-id>   # messages for a specific engagement
```

After reading, decide whether to trigger a manual re-review (`arb review --pr
<url>`) or post a direct reply on the PR. There is no automated command to
switch an engagement from `:flag` to `:auto` mid-flight; update
`auto_authors` and re-dispatch a new review if needed.

---

## Hard Invariants (do not break)

1. `review_only == true` engagements must NEVER update a linked tracker issue.
   SyncTracker enforces this; do not add `close_upstream: true` to review
   engagement close calls.
2. ReviewPatrol must NEVER dispatch a normal `Worker.start/1` run. Only
   `review_only` sub-runs are permitted.
3. Multi-reviewer isolation: ReviewPatrol only acts on threads opened by the
   fleet login (`our_login`). Another reviewer's CHANGES_REQUESTED or comment
   thread is completely ignored, even if the PR author replies on it.
