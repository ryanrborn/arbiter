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
| `review_automation` | `:auto`, `:report_only`, or `:flag` — controls re-review and reply behaviour (see "Automation modes") |
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

## Automation modes (`auto` vs `report_only` vs `flag`)

Every engagement — and every one-shot external review — resolves to one of three
automation modes. The mode decides **whether findings get posted to the PR** and
**who greenlights them**:

| Mode | Reviews? | Posts to PR? | Behaviour |
|---|---|---|---|
| `:auto` | yes | **yes** — inline comments + verdict | Fully autonomous review. Used for authors/repos the fleet is trusted to comment on directly (`auto_authors`, or a `repo_overrides` set to `auto`). |
| `:report_only` (alias `propose`) | yes | **no** | Human-in-the-loop. The reviewer runs the full review — reads the diff, computes findings + a recommended verdict — but posts **nothing**. It surfaces the findings and the exact **per-finding proposed comment text** to the coordinator mailbox (and, for the first pass, onto the `ExternalReview` audit record). A coordinator then **greenlights** which comments actually post. This is the required default for infra repos (`atlas`, `verus-infrastructure`). |
| `:flag` (alias `notify`) | **no** | no | Pure escalation. Do NOT review — just raise a mailbox flag/escalation so a human notices the new commits or reply and decides what to do. The "ping me, don't review" stance. |

The distinction is deliberate: `report_only` **reviews and reports**, whereas
`flag` **only pings** (it never reads the diff). Infra review is `report_only`,
not `flag` — the earlier `flag`-for-infra wiring was corrected in bd-36qzgx.

### Greenlighting a report-only review

A report-only first-pass review persists its proposed comments on the
`ExternalReview` record (`mode: :report_only`, `greenlight_status: :pending`) and
mails them to `to_ref: "coordinator"`. The coordinator posts the approved subset with
the `review_greenlight` MCP tool (backed by
`Arbiter.Reviews.ExternalReview.greenlight/1`):

```
review_greenlight record_id=<id> select=all        # post every proposed comment
review_greenlight record_id=<id> select=[0,2]      # post only comments #0 and #2
review_greenlight record_id=<id> select=[]         # approve nothing (true no-op)
```

Only the selected comments post; un-approved findings never reach the PR. When at
least one comment is approved the recommended verdict is also submitted (override
with `post_verdict`). The record's `greenlight_status` flips to `:posted` (or
`:none` when nothing was approved).

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

If automation mode is `:report_only`, ReviewPatrol runs the full re-review
(new-diff-only + dedupe, exactly as `:auto`) but posts **nothing** to the PR.
Instead it sends an `:escalation` to `to_ref: "coordinator"` carrying the proposed
comment text, records the reported findings in `posted_findings` (so they aren't
re-reported), and advances `last_reviewed_sha`.

If automation mode is `:flag`, **no review runs at all**. ReviewPatrol sends
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
- **`:report_only` / `:flag`** — posts NOTHING to the PR. Raises exactly one
  `:escalation` message addressed to `to_ref: "coordinator"` with the PR link, thread
  path, and a 280-char body snippet. A human decides whether to reply or trigger a
  re-review. (Author replies are a conversation, not a diff, so `report_only`
  escalates them rather than auto-drafting a reply.)

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
      │             :auto        → CodeReview sub-run (new-diff-only, dedupe), POST
      │             :report_only → CodeReview sub-run, POST NOTHING → escalate proposed comments
      │             :flag        → send mailbox flag (no review), advance cursor
      └─ no   →  new author replies on our threads?
                   none → nil (nothing to do this tick)
                   some →
                     automation?
                       :auto                 → ReviewReply sub-run (in-thread)
                       :report_only / :flag  → one :escalation to "coordinator", advance cursor
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

To set the patrol interval (default: 60 s), set the `:review_patrol_interval_ms`
application env before boot — for example in `config/runtime.exs`:

```elixir
config :arbiter, review_patrol_interval_ms: 120_000   # 2 minutes
```

Or pass it as a release environment variable if your deployment uses
`Config.Provider`. The value is read once at `ReviewPatrolSupervisor` init, so
a server restart is required for the change to take effect.

> **Note:** `arb config set` writes to the workspace config (runtime deep-merge)
> and is **not** read by the patrol interval logic. Use the application env above.

### Configuring the fleet login (author-reply handling)

Author-reply detection uses the fleet's own GitHub login to identify threads we
participated in. Set it via:

```bash
arb config set review_patrol.our_login "your-bot-account"
```

Without this, author-reply handling is conservatively skipped.

### Configuring automation mode per workspace

`review_automation` controls the default stance for new engagements in the
workspace. Resolution order (most-specific wins):

1. **Per-dispatch override** — the `automation` argument to `worker_review` always wins
   (`auto` | `report_only` / `propose` | `flag` / `notify`).
2. **Per-repo override** — `review_automation.repo_overrides[rig_name]` hard-gates a
   specific repo regardless of PR author.
3. **Author list** — if the PR author is in `auto_authors`, the mode is `:auto`.
4. **Default** — `review_automation.default` (`:flag` when unset).

The three accepted mode values are `auto`, `report_only` (alias `propose`), and
`flag` (alias `notify`) — see "Automation modes" above for what each does.

```bash
# Authors who get automatic re-reviews and threaded replies (auto: review + post)
arb config set review_automation.auto_authors '["alice","bob"]'

# Default stance for authors NOT in the list: "auto" | "report_only" | "flag" (default: "flag")
arb config set review_automation.default "report_only"

# Hard-gate specific repos regardless of author — infra is review-and-report-only
arb config set review_automation.repo_overrides '{"atlas": "report_only", "verus-infrastructure": "report_only"}'
```

Authors in `auto_authors` get `:auto` mode (automatic re-reviews and threaded
replies). Authors not in the list fall back to `review_automation.default`
(`:flag` mode when unset — coordinator escalation only, no automatic posting).

**Per-repo overrides** (`repo_overrides`) take precedence over the author list.
Setting `atlas: "report_only"` ensures atlas PRs are always fully reviewed but
never auto-posted — the findings + proposed comments go to the coordinator to
greenlight — even when the PR author is in `auto_authors`. The key is the rig
name as defined in `merge.config.repo_paths` (or `rig_paths`).

Example: a workspace with backend engineers trusted for auto-review, while the
infra repos are review-and-report-only (never auto-post):

```json
"review_automation": {
  "default": "flag",
  "auto_authors": ["alice", "bob"],
  "repo_overrides": {
    "atlas": "report_only",
    "verus-infrastructure": "report_only"
  }
}
```

With this config: an atlas PR by alice resolves to `:report_only` (reviewed,
nothing posted, proposed comments await a coordinator greenlight); a backend PR
by alice resolves to `:auto` (reviewed and posted).

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
  `to_ref`: `"coordinator"`) lands in the coordinator inbox. It includes the PR link,
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
