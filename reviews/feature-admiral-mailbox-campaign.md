# Review: Admiral mailbox campaign (bd-bduz2k · bd-aegwbn · bd-25ftl0)

**Beads:** bd-bduz2k (Message resource + core API), bd-aegwbn (`arb inbox` / `arb msg` CLI + prime), bd-25ftl0 (acolyte lifecycle auto-posts)
**Reviewed under:** bd-3ki0x5
**Builders:** polecats — PR #19 (bd-aegwbn, carries the bd-bduz2k foundation), PR #18 (bd-25ftl0)
**Reviewer:** polecat (bd-3ki0x5)
**Date:** 2026-05-28

## Verdict

**APPROVE WITH CHANGES — one required fix, one design decision to confirm.**

The campaign is high-quality, well-documented, and cohesive. The Message
resource, REST layer, CLI commands, and prime section are correct and
thoroughly tested (44 campaign tests green: 22 arbiter, 11 web, 11 CLI for the
new commands). Two items need the Admiral's eye before this merges:

1. **Required.** The lifecycle auto-posts (bd-25ftl0) are **synchronous**, not
   async. The directive — and this review bead's own acceptance list —
   explicitly require "async, fire-and-forget, do not block the Machine."
   They currently run 2–3 blocking DB calls inside the `Arbiter.Polecat`
   GenServer callbacks.
2. **Confirm.** Lifecycle events post as **broadcast `:notification`s** (the
   web dashboard feed), *not* as addressed mail to `to_ref: "admiral"`. They
   therefore **do not appear in `arb inbox` or `arb prime`'s Admiral Inbox**.
   This diverges from the literal bd-25ftl0 spec but is internally coherent and
   openly documented. If the intent is that the Admiral sees completions/
   failures from the terminal, this is a gap; if the dashboard feed is the
   intended surface, it's fine as-is.

Everything else is non-blocking polish.

## Diff summary

A server-side mailbox so the Admiral (and any named recipient or bead) receives
messages from acolytes, the system, and the CLI.

- **`Arbiter.Messages.Message`** (bd-bduz2k) — *extends the existing* Messages
  resource from PR #3 rather than creating a new `Beads.Message`. Adds the
  `directive_ref` attribute, the Admiral mailbox kinds
  (`:completion :failure :escalation :info`), and helpers `inbox/2`,
  `recent_notifications/2`, `notify/1`, `send_mail/1`, `mark_read/1`. One
  migration (`AddMessageDirectiveRef`) — the `messages` table itself predates
  this campaign. PubSub `{:new_message, _}` broadcast on create via
  `after_action`.
- **REST** (`ArbiterWeb.Api.MessageController` + JSON view) — `GET /api/messages`
  (filters: kind, to_ref, from_ref, `unread=true`, limit), `POST /api/messages`,
  `POST /api/messages/:id/read`, `DELETE /api/messages` (clear). Newest-first.
- **CLI** (bd-aegwbn) — `arb inbox` (admiral unread), `--all`, `read <id>`
  (prefix-resolvable), `clear`, and `arb inbox <bead-id>` (acolyte drain path);
  `arb msg <recipient> <body>` with `--subject/--directive/--kind`; both wired
  into `main.ex` dispatch and `alias_resolver`. `arb prime` gains an
  **Admiral Inbox** section (up to 5 unread, omitted when empty).
- **Lifecycle auto-posts** (bd-25ftl0) — new `Arbiter.Messages.AdmiralNotifier`
  with `completed/1`, `failed/1`, `awaiting_review/1`. Wired into
  `Arbiter.Polecat`'s done/await/fail transitions (replacing the old inline
  `record_done_notification`). Gated per workspace by
  `config["admiral_notifications"]` (default true).

## Acceptance criteria check (from bd-3ki0x5)

- [x] **Message resource has correct schema and queries** — kinds constrained,
  `workspace_id` required, `directive_ref`/`read_at` present, indexed on
  `[:workspace_id, :to_ref, :read_at]`. `inbox/2`, `recent_notifications/2`,
  `mark_read` all correct. *Deviation, accepted:* implemented by extending the
  existing `Arbiter.Messages.Message` (DRY) instead of the spec's literal
  `Arbiter.Beads.Message` with `to`/`from` fields — a better call.
- [x] **Migration is present** — `20260529022126_add_message_directive_ref.exs`
  (table created earlier in PR #3). Snapshot updated. `mix ecto.migrate` clean.
- [x] **CLI commands match spec** — inbox list/read/clear and msg send all
  present and behave per spec; `read` accepts a short id prefix; help/usage and
  alias resolution updated.
- [x] **`arb prime` shows unread correctly** — `== Admiral Inbox (N unread) ==`,
  top 5, omitted when empty. Matches the spec header. Two new prime tests pass.
- [ ] **Lifecycle auto-posts are async and don't block the Machine** — *NOT
  MET.* Posts are synchronous (see Required finding R1).
- [x] **`admiral_notifications` config flag works** — default-on; only an
  explicit `false` disables; unreadable workspace falls back to enabled.
  Directly tested end-to-end through the polecat.
- [x] **Tests cover the core paths** — create/validation, PubSub, inbox/mark_read,
  admiral kinds, controller (incl. clear-only-read + requires-to_ref), CLI
  inbox/msg/prime, and all three lifecycle events + the disabled flag.

## Verification performed

- Merged both branches into a clean bd-3ki0x5 worktree (no conflicts).
- `mix compile` clean; `mix ecto.create/migrate` clean.
- `arbiter`: `message_test`, `admiral_notifier_test`, `polecat_notification_test`
  → **22 tests, 0 failures.**
- `arbiter_web`: `message_controller_test` → **11 tests, 0 failures.**
- `arbiter_cli`: `inbox_test`, `msg_test`, `prime_test` → 25 tests, **2 failures
  — both pre-existing on `main`** (see Notes), the 4 new mailbox prime tests pass.
- Traced the message channels end to end: confirmed lifecycle `:notification`s
  feed `dashboard_live` (`recent_notifications/20`) and that `arb inbox`/`prime`
  query `to_ref == "admiral"`, so the two never intersect (finding C1).

## Findings

### Required (address before merge)

**R1 — Lifecycle auto-posts are synchronous; the directive requires async.**
`Arbiter.Polecat` calls `AdmiralNotifier.completed/failed/awaiting_review`
inline in its GenServer callbacks (`broadcast_done`, and the `:await` / fail
`handle_call` clauses). Each call runs `enabled?/1` (`Ash.get(Workspace)`) +
`title_for/1` (`Ash.get(Issue)`) + `Message.notify/1` (`Ash.create`) — two reads
and a write — **synchronously**, before the GenServer replies. bd-25ftl0 says
verbatim: *"Keep it async — fire and forget, do not block the Machine on message
creation,"* and bd-3ki0x5 lists it as an acceptance item. The internal `rescue`
guards against message-subsystem *errors* but not against *latency*: a slow or
stalled DB connection blocks the polecat's `await`/`done`/`fail` transition (and,
for `:await`, the calling process too).

*Fix:* run the post in a detached, supervised task — capture the snapshot
synchronously (it's in-memory and cheap), then
`Task.Supervisor.start_child(..., fn -> AdmiralNotifier.completed(snap) end)`.
*Note for the fixer:* `polecat_notification_test` reads `recent_notifications`
**immediately** after the transition and only passes because the post is
synchronous — making it async will require those assertions to wait
(e.g. an `assert_eventually` / receive-loop helper). The tests currently *lock
in* the behaviour the directive forbids.

### Confirm with the Admiral (design decision, not a defect)

**C1 — Lifecycle events never reach the CLI inbox.** Auto-posts are `:notification`
kind with `to_ref: nil` (via `Message.notify/1`), so they surface on the web
dashboard feed but are invisible to `arb inbox` and `arb prime`'s Admiral Inbox,
both of which filter `to_ref == "admiral"` (and `inbox/2` excludes `:notification`
outright). The bd-25ftl0 spec asked for `to="admiral"`, dedicated
`:completion`/`:failure` kinds, and `directive_ref=bead_id` — which *would* have
landed in the CLI inbox. `AdmiralNotifier`'s moduledoc reconciles this honestly
and the realised two-channel design (broadcast feed vs. addressed mailbox) is
coherent. **Decision needed:** is the dashboard the intended Admiral surface for
lifecycle events, or should completions/failures also be addressed to "admiral"
so they show up in `arb inbox`? If the latter, switch the notifier to
`Ash.create` with `kind: :completion|:failure`, `to_ref: "admiral"`,
`directive_ref: bead_id`.

### Suggested (non-blocking — file follow-up beads)

- **S1 — `body` isn't actually required.** `attribute :body` is
  `allow_nil? false, default ""`, so a message with an empty body is accepted.
  bd-bduz2k said body is required. If a non-empty body matters, add a
  `validate present(:body)` / length constraint; otherwise drop the doc claim.
- **S2 — `mark_read` re-stamps on every call.** It unconditionally sets
  `read_at = now()`, so re-reading an already-read message moves its timestamp.
  Harmless, but the spec wanted "set if nil (idempotent)." A `change` that
  no-ops when `read_at` is already set would match intent.
- **S3 — `inbox/2` sorts oldest-first (`:asc`) while bd-bduz2k said
  `created_at desc`.** Only the resource helper (used by the polecat-detail
  mailbox panel) differs; the REST controller that the CLI uses sorts
  newest-first, so the CLI is fine. Worth aligning the helper or the spec.
- **S4 — lifecycle posts use `from_ref` for bead linkage, not `directive_ref`.**
  The rest of the system (e.g. `arb msg --directive`) uses `directive_ref` and
  `arb inbox` renders it in `[brackets]`. Setting `directive_ref: bead_id` on
  auto-posts too would keep the convention consistent (relevant only if C1
  routes them to an inbox view).
- **S5 — `arb msg admiral --kind notification` produces a mixed state** — a
  `:notification` that also carries `to_ref: "admiral"`. It would show in the
  controller's admiral view (no kind filter) but be excluded by `inbox/2`.
  Low impact (default kind is `info`); consider rejecting `notification` from
  `arb msg`, which is for addressed mail.

## Notes

- **Pre-existing test failures, not this campaign's:** `prime_test`'s "prints
  all four sections" and "empty vernacular reports 'default gas-town'" fail on a
  clean `main` too. Cause is unrelated — `prime.ex` reads vernacular from
  `/api/settings` (and emits `(defaults)`), while those stale tests stub it in
  `workspace.config` and assert `(default gas-town)`. Housekeeping for a separate
  bead; it does not block this campaign.
- The `clear` endpoint's safety is solid: it destroys only read mail and refuses
  to run without `to_ref` — both directly tested.
- Nice touches: prefix-resolvable `arb inbox read <id>`, the acolyte
  auto-drain path (`arb inbox <bead-id>`), and the consistent best-effort/
  debug-breadcrumb contract mirrored from `Polecat.broadcast_lifecycle/2`.
