# External Review Visibility Page — Design Document

**Status:** proposed (design only — no implementation in this ticket)
**Task:** bd-4jllkg
**Follow-up:** a `feature` ticket will be filed once this design is accepted,
same pattern as vs-3mitja → bd-6tsseu.

---

## Problem

External reviews (`worker_review(pr:)` / the `external_review` MCP tool /
`arb review --pr`) run against PRs that are **not** arbiter tasks — no task
card, no board column. Today the only way to observe one happen is the live
`GET /events?subscribe=external_review` stream (`docs/monitoring.md`); once
an event scrolls past, it's gone. There is no page that shows external
reviews, their in-flight progress, or their results.

The data already exists and is fully queryable — this is a pure UI gap:

* `Arbiter.Reviews.Record` (`apps/arbiter/lib/arbiter/reviews/record.ex`) —
  the audit-ledger resource, one row per review run.
* `GET /api/external_reviews` — already supports `workspace_id`, `status`,
  `since`, `limit`, newest-first
  (`apps/arbiter_web/lib/arbiter_web/controllers/api/external_review_controller.ex`).
* `external_review_list` MCP tool — same data, MCP-transport naming.
* The `external_review` PubSub topic already broadcasts `running` →
  `completed`/`failed` transitions (`Arbiter.Events`, fired from
  `Arbiter.Reviews.ExternalReview.create_review_record/2` and
  `complete_review_record/3`).

No backend work is needed for a basic page. This document is about layout,
filtering, live-update wiring, and how far the greenlight workflow should be
pulled into the UI.

---

## 1. Placement

**Recommendation: a new standalone AppShell nav page at `/reviews`**, styled
after the two most recent standalone pages — Usage (`/usage`,
`ArbiterWeb.UsageLive`) and Audit Log (`/audit`, `ArbiterWeb.AuditLogLive`).

External reviews are explicitly *not* task-linked (no `Issue`, no board
column) — they don't fit Backlog/Ready/Running/Review/Done, which are
task-lifecycle states, not review-run states. A `review_only` engagement
issue may exist for a PR *after* its first review posts (see §3, "linked
engagement"), but the review record itself predates and can outlive any such
engagement, so the record — not the engagement — is the primary entity this
page is built around.

Nav entry: add `%{label: "Reviews", href: ~p"/reviews"}` to the global-chrome
`nav_items/0` list in `apps/arbiter_web/lib/arbiter_web/components/layouts.ex`
(bd-53pfbg), between "Loop"/"Usage" and "Audit" — reviews are, like usage and
audit, cross-cutting operator visibility rather than a task-management view.

---

## 2. List view

A single-table LiveView, same shape as `AuditLogLive`: filter controls above
a paged/scrollable table, with `handle_params/3` round-tripping filters
through the URL (`?workspace_id=&status=&page=`) so the view is shareable
and back-button safe, matching the Audit Log page's existing convention.

### Columns

| Column | Source | Notes |
|---|---|---|
| Started | `started_at` | Relative + absolute on hover, like other list pages. |
| PR | `link` (fallback `pr_ref`/`pr`) | External link icon to the forge PR. |
| Workspace | `workspace_id` | Resolve to workspace name if a lookup is cheap/cached; otherwise show the id. |
| Strategy | `strategy` | `github` / `gitlab` / `direct`, as a small badge. |
| Status | `status` | `running` / `completed` / `completed_unposted` / `failed` — see badge semantics below. |
| Mode | `mode` | `auto` vs `report_only` — determines whether the greenlight affordance is shown (§5). |
| Verdict | `verdict` | `approve` / `request_changes`, nil while running. |
| Findings | `finding_count` | Numeric; nil while running. |
| Cost | `cost_usd` | Formatted like the Usage page's cost figures; nil when not captured. |

Status badge semantics (reuse `ArbiterWeb.CoreComponents.Data.status_chip/1`
or the live/fail/attention hue tokens already used elsewhere, e.g.
`--arb-live`, `--arb-fail`):

* `running` → live/in-progress hue.
* `completed` → success hue.
* `completed_unposted` → attention hue (ran fine, but posting failed and
  findings are sitting unposted — this is the state an operator most needs
  to notice, since it's actionable via greenlight/retry).
* `failed` → fail hue.

### Filters

At minimum, matching what the API already supports:

* **Workspace** — dropdown/select, sourced the same way other pages resolve
  workspace lists (e.g. the quota nav bars).
* **Status** — tabs or a select, matching `Record.statuses/0`
  (`running | completed | completed_unposted | failed`).

A free-text search (PR ref, like the Audit Log mono search box) is a
reasonable v1.1 addition but isn't required to close the visibility gap —
recommend deferring it unless implementation finds it cheap to add
alongside the two required filters.

### Pagination

Reuse `ArbiterWeb.Paging`, same as `AuditLogLive`. The API's `limit`/`since`
params are sufficient to back a "load more" or classic pager; either is
fine, follow whichever `AuditLogLive`/`UsageLive` already established for
consistency (Audit Log uses a classic pager via `Paging`).

---

## 3. Detail view / expansion

**Recommendation: inline row expansion (accordion-style), not a separate
route.** Review records are lightweight and the operator's workflow is
"scan the list, drill into the one that needs attention" — a modal or
expandable row keeps them in list context without a page navigation
round-trip. This also sidesteps needing a new `/reviews/:id` route + its own
`handle_params` state.

Expanded content, conditional on status/mode:

* **Always:** `findings_summary`, `model`, `tokens_in`/`tokens_out` (if
  present), `dispatched_by`, full `pr`/`pr_ref`.
* **`completed_unposted` or `report_only` with `greenlight_status: :pending`:**
  the `proposed_comments` list (file/line/severity/message/body per entry)
  — see §5 for the greenlight affordance.
* **`failed`:** `failure_stage` and `failure_reason`, prominently — this is
  the state an operator most needs a fast diagnostic path for.
* **Linked engagement:** when a `review_only` Issue exists for this PR
  (`engagement_id` is already populated on the record when ReviewPatrol
  adopted it — see `Arbiter.Reviews.ExternalReview`'s `engagement_id` field
  and the `(source_pr, workspace)` lookup around line ~1208 of
  `external_review.ex`), render a link to that task's board/detail page.
  This is a straight `engagement_id` → task link render, no new lookup
  logic needed — the association is already persisted on the record at
  review-completion time.

---

## 4. Live updates

**Recommendation: subscribe to the `external_review` PubSub topic via
LiveView, same pattern the codebase already uses for other live pages/event
consumers** (`Arbiter.Events.pubsub_topic/1` + `Phoenix.PubSub.subscribe`,
`Arbiter.Events.broadcast/3` fires the topic from
`create_review_record/2`/`complete_review_record/3`).

On mount, subscribe to the current workspace-filtered topic (or the global
`"events"` topic when no workspace filter is set, mirroring how the
`/events` SSE controller already offers both scopes). On `{:event, %{topic:
"external_review"} = payload}`:

* If the event is a new `running` record and it matches the active filters,
  prepend it to the list (or increment an "N new — refresh" banner if the
  operator has scrolled past the top, a pattern worth borrowing from chat-UI
  conventions but not essential for v1).
* If it's a `completed`/`failed`/`completed_unposted` transition for a
  record already in the visible page, patch that row in place rather than
  re-querying.

Rationale for live over polling: the codebase already has the PubSub
infrastructure wired end-to-end for this exact topic (it exists *only* to
serve the `/events` stream today), LiveView makes consuming it nearly free,
and "watch a review go from running to done" is the core visibility gap
this ticket exists to close — a page that requires a manual refresh to see
that transition only partially fixes it.

Fallback: keep a manual refresh/reload action for correctness after a missed
message (LiveView reconnect, etc.) — same safety net `UsageLive` uses
(refresh-on-load), just not the primary update path here.

---

## 5. Report-only greenlight UX

**Recommendation: consider it in this design, defer the write-path
implementation to a v1.1 (or the first cut, if implementation finds it
cheap) — but design the detail view so it's a natural slot-in, not a
retrofit.**

Current state: `Arbiter.Reviews.ExternalReview.greenlight/1` takes
`record_id` + `select` (`:all`, a list of indices, or `[]`), posts the
approved subset of `proposed_comments`, and optionally submits the
recommended verdict. It's currently only reachable via the `review_greenlight`
MCP tool / CLI; `render_report_body/2` already generates the human-readable
instructions mailed to the coordinator today.

Proposed UI, for a record with `mode: :report_only` and
`greenlight_status: :pending`:

* In the expanded detail (§3), render each `proposed_comments` entry as a
  checkbox row (file:line, severity badge, message, and the exact comment
  `body` text collapsed/expandable).
* "Select all" / "select none" shortcuts, since `select: :all` and
  `select: []` are both meaningful, distinct actions (approve everything vs.
  a deliberate "approve nothing" no-op — not the same as ignoring the row).
* A single "Post selected" button that calls `ExternalReview.greenlight/1`
  with the checked indices, then patches the row's `greenlight_status` and
  re-renders it as posted (no polling needed — this is a direct LiveView
  event handler, not a PubSub-driven update).
* Post-greenlight, show `verdict_posted` and a link to the newly-posted
  comments if the adapter's response includes one.

Why defer the write path is a legitimate v1 option rather than a design gap:
the read-only list+detail view alone closes the actual visibility gap named
in the ticket (operators can currently see *nothing*; seeing pending
greenlights and their proposed text, even without an in-UI post button, is
already a large improvement over scrollback-only visibility via `/events`).
Wiring the button is a contained addition once the page exists, since
`greenlight/1`'s contract already matches "list of indices" 1:1 with
checkbox state — there's no new backend surface to invent, just a
`handle_event` calling an existing function. Implementation should decide
based on time budget; this design doesn't require it for v1 to be
considered done.

---

## Summary of recommendations

1. Standalone page at `/reviews`, nav entry beside Usage/Audit Log.
2. List: started/PR/workspace/strategy/status/mode/verdict/findings/cost
   columns; workspace + status filters (API already supports both);
   `ArbiterWeb.Paging` for pagination.
3. Inline row expansion for detail (findings, proposed comments,
   failure diagnostics, linked engagement task) — no separate route.
4. Live updates via the existing `external_review` PubSub topic, LiveView
   subscribe + patch-in-place; manual refresh as the reconnect fallback.
5. Design the detail view to hold a greenlight affordance
   (`ExternalReview.greenlight/1` behind checkboxes); implementation may
   ship it in v1 or defer to a fast v1.1 follow-up — the read-only view
   alone already resolves the visibility gap.
