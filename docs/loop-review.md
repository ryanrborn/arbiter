# Loop review — the operator-invoked loop-analysis pass (`/loop-review`)

Stage 1 of the loop-engineering epic (#1011), task `bd-dyfaq3`. This is the
operator runbook for the pass. It is the source of the `/loop-review` skill; the
skill is materialized from this doc into `.claude/skills/loop-review/SKILL.md`
(that directory is git-ignored, so this tracked doc is the canonical copy).

## What it is

An **operator-invoked**, **report-only** pass that reads the loop's own
telemetry over a window and tells you where — if anywhere — a prompt/skill/
difficulty change is warranted. It is manual on purpose: per the operator
decision of 2026-07-28, *"manual first at first, later it will be automated."*

Run it:

```
arb loop analyze --since 7d        # weekly is a sensible cadence
arb loop analyze --since 7d --json # markdown + a structured summary envelope
```

Under the hood it hits `GET /api/loop/analyze`, which runs
`Arbiter.Loop.Analysis.analyze/1`.

Offline / server-not-running, there is a direct entry point that starts only
the database layer (never the worker fleet, web endpoint, or patrols, so it is
safe on a live box):

```
mix arbiter.loop.analyze --since 7d [--out report.md] [--no-ledger]
```

## Hard constraint: zero writes

The pass **writes nothing** — no skill edits, no config changes, no task
overrides. It emits a markdown report and a single `usage_events` cost row for
its own compute (so the loop's cost lands in the ledger it is optimising). You
read the report and decide. (Stage 2's opt-in `--propose` adds rows to the
reviewable queue below and *still* applies nothing; see
[The proposal queue](#the-proposal-queue-stage-2-bd-9j2g3x).) This mirrors the
`report_only` + greenlight
precedent used for coworker-facing review automation, which exists *because*
unreviewed automation once caused real damage. A self-modifying prompt loop
warrants at least the same gate.

## What the report gives you, and how to read it

1. **Failure segmentation (allowlist, not heuristic).** Failures are split into
   *operational* (server restarts, rate-limits, auth, merge/CI infra — routed
   to ops, **excluded** from prompt-shaping) and *agent-quality*
   (`:review_gate_rejected`, never signalled `arb done`, uncommitted/no-commits
   at completion, secret-in-commit, and **context exhaustion**). `server
   restarted` is the modal failure by ~4×; a naive `status = failed` pass would
   spend its whole budget on our own deploy restarts. Only agent-quality
   failures can be moved by a prompt or skill change.

2. **Corpus-integrity: the misclassification rate.** `failure_reason` is a
   hint, not ground truth. Before a run is filed operational, its transcript's
   terminal signal is checked. The report surfaces the rate at which the label
   disagreed with the transcript — a first-class finding. The validating case is
   run `c88c77b0-2927-41ec-b582-6210538a43b3`: recorded "agent was rate-limited
   / the API was overloaded", but the transcript shows an **autocompact thrash**
   — **context exhaustion**, the purest agent-quality signal in the corpus,
   which the label would have hidden as ops noise. Detection keys on the
   autocompact-thrash fingerprint (`Autocompact is thrashing` / "context window
   thrashed"), *not* on a bare `claude session error`: on the real corpus a bare
   session error ends nearly every failed run regardless of cause, so keying on
   it would reclassify server restarts and auth failures as agent-quality. If
   the misclassification rate is material, fix the labelling before trusting any
   downstream metric.

3. **Reviewer-finding categories**, clustered, with run citations — e.g.
   *"plausible code, green tests, inert at runtime."*

4. **Difficulty misestimates**, segmented by `(difficulty, repo)` cell — tasks
   where the dispatched difficulty under-provisioned the actual cost/rounds.

5. **`(difficulty, repo)` cells** with rework rate and mean cost. Compare
   *within* a cell: metrics move with difficulty mix and repo, so cross-cell
   comparison reads drift as improvement.

6. **Suggestions.** Each names the metric it should move, that metric's current
   baseline, and a destination.

## The discipline the report enforces — and you must too

- **Evidence bar for any fleet-wide suggestion: ≥ 3 incidents across ≥ 2
  distinct tasks.** A single incident is blast-radius-1: it goes to a per-task
  `Issue.difficulty` / `Issue.skills` override, paper-trailed, plus a tracked
  hypothesis — **not** a routing change. The worked example `bd-7rspia` (a D1→
  Haiku attempt that was green-but-inert and rejected over 2 rounds, re-filed
  D2→Sonnet, approved round 1; real cost **$10.62**, the successful Sonnet
  author costing 2.4× the failed Haiku one) is a difficulty misestimate — but
  n = 1, so the pass **declines** a fleet-wide change and recommends the
  per-task override. If a pass ever proposes a routing change from a single
  case, it is mis-built.
- **Every suggestion names its target metric and current baseline.**
- **Report effect sizes with sample counts.** At ~15 dispatches/day most
  single-window deltas are not statistically significant; treat them as
  hypotheses.
- **Two-sided.** A change that raises convergence but doubles cost per task is
  not a win.

## The proposal queue (Stage 2, `bd-9j2g3x`)

Stage 1 hands you a report and forgets it. Stage 2 gives the report a memory: run
the pass with `--propose` and every suggestion it implies is persisted as a
reviewable **`PendingWrite`** row — a queued write, never an applied one.

```
arb loop analyze --since 7d --propose    # analyze, then queue what it implies
arb loop pending                         # the live queue (hypothesis + proposed)
arb loop diff <id>                       # gist, evidence, and the full unified diff
arb loop apply <id>                      # or: arb loop apply all --state proposed
arb loop reject <id> --reason "handled in CLAUDE.md instead"
```

Without `--propose` the pass is **byte-identical to Stage 1** — the zero-writes
guarantee above still holds, and it is structural: `--propose` is a different
verb on a different route (`POST /api/loop/propose`), not a flag on the
report-only `GET /api/loop/analyze`.

The same queue is on the dashboard at `/loop` (gist + state + evidence in the
list, the full diff in the detail pane) and over MCP as `loop_pending_list` /
`loop_pending_diff` / `loop_pending_apply` / `loop_pending_reject` — all
**coordinator-tier only**, so a worker can never apply a fleet-wide change.

Every live row — `fleet`-scoped included — carries a real `workspace_id`
(bd-3dasqm); `scope: :fleet` alone is the fleet marker, never a null
`workspace_id`. A `:fleet` candidate raised with no workspace of its own is
attributed to the installation's default workspace (the sole workspace, or
the one named `default` when there are several), the same fallback used for
escalation routing. There is currently no representation of a finding that
genuinely spans more than one workspace — an install where that attribution
is ambiguous (several workspaces, none named `default`) has the row refused
outright (`{:error, :ambiguous_workspace}`) rather than written with a null
FK. A workspace-bound caller (dashboard, MCP, `arb loop pending`) only ever
sees rows in its own workspace, so the same finding does not read as N
findings across N workspaces.

### Cross-window accumulation: a below-bar finding is kept, not dropped

Stage 1's evidence bar (≥ 3 incidents / ≥ 2 distinct tasks) is still the gate on
a fleet-wide change, but a finding that misses it is no longer thrown away and
recounted from zero next week. It lands as a **`hypothesis`** carrying its
incident refs, and a later window that produces the same finding **reinforces**
that row in place:

- Matching is by a deterministic **fingerprint** over
  `{kind, target, category, difficulty, repo}` — a SHA-256 of a canonicalised
  tuple, never an LLM comparison of two gists.
- Reinforcing **unions** the incident and task refs and recomputes
  `evidence_count` / `distinct_tasks` from the union, so re-running the pass over
  the same window is idempotent: two consecutive `--propose` runs produce no
  duplicate rows and no inflated counts.
- Crossing the bar promotes `hypothesis → proposed` and posts **exactly one**
  escalation to the coordinator mailbox (guarded by `escalated_at`).
- A `task`-scoped proposal **bypasses** the bar entirely — blast radius 1 is the
  per-task override the discipline above already prescribes.
- Applying is never automatic, at any evidence level. `arb loop apply` on a
  `hypothesis` refuses and names what the row still needs.

The bar is configurable per workspace, through the deep-merge config surface:

```
arb config set loop.evidence_bar.min_incidents 4
arb config set loop.evidence_bar.min_distinct_tasks 3
```

Absent keys fall back to the documented `3` / `2`.

### Every proposal is priced before it is approved

The goal is a system that learns from itself *without growing worker contexts too
much with those learnings*. A lesson the loop persists is not paid once at apply
time — it is paid again by every dispatch that carries it, forever. So each row
records **`context_cost_tokens`**: the recurring per-dispatch context the
proposal would add if applied.

- A **`task`-scoped override is 0** — blast radius 1 is charged once, against the
  one task that carries it, and never lands in another dispatch's prompt.
- A **`difficulty_override` is 0** at any scope — it is a routing change (*which*
  model runs), not prompt content. A **`config_set` is 0** for the same reason.
- Anything else fleet-wide is **prose that every future dispatch carries**, and
  is priced at the clause length in *tokens*, not bytes. Skill clauses skew
  toward paths, flags and code fragments, which tokenize far worse than prose, so
  a byte count under-reads exactly the content most likely to be added. The
  estimate is a deliberate local approximation (~4 chars/token) rather than a
  tokenizer call: it runs inside the analysis pass, which stays free of network
  I/O and LLM calls.

The figure is shown in `arb loop pending` (a `+120ctx` / `free` column), in
`arb loop diff`, over MCP, and on the dashboard next to the evidence counts — so
a fleet-wide prompt addition cannot be approved without its standing price in the
same glance as the case for paying it. Reinforcement re-estimates it from the
current gist rather than leaving it stale at the first window's figure.

The unit of account behind this is worth stating plainly: on a subscription,
dollars are imputed. **Quota headroom is the binding constraint**, and context is
how the loop spends it. A clause that adds 200 tokens to every dispatch is a
standing withdrawal from the same budget the work itself needs — which is why the
price is surfaced at the approval point rather than measured afterwards.

### Applying goes through the front door

`apply` dispatches on `kind` to the *same public domain API a human would call*
— `Arbiter.Skills.update_skill/2`, the workspace `:patch_config` deep-merge, an
`Issue` update — so the queue never writes those tables directly and every
application leaves a normal paper-trail version attributed to
`loop:proposal:<id>`. Read a skill's or a task's history and you can see exactly
which queued proposal moved it.

Rejection is **soft**: the row persists as `rejected` (nothing is ever deleted)
and keeps accumulating evidence for the record, but is deliberately not
re-proposed from scratch — a decision you already made is not re-litigated
every window. `applied` rows are also not re-matched: a recurrence after an apply
is a *new* hypothesis, which is precisely the signal that the fix did not land.

Every state change publishes on the opt-in `loop_proposal` event topic
(`/events?subscribe=...,loop_proposal`).

What Stage 2 deliberately does **not** do: measure whether an applied proposal
moved its `target_metric` (the `baseline` is pre-registered at propose time
against that later re-grading pass), and author skill-patch *content* — no
finding-category → skill mapping exists yet, so a `skill_patch` row with no
target skill refuses to apply and says so.

## Autonomous routing-tier adjustment (Stage 3, `bd-6edc0u`) — opt-in, default off

Stage 3 lets Arbiter apply **one** narrow class of queued proposal without a
human: a routing-tier adjustment — a single `D<n>` tier's `model_tier` /
`thinking`. Nothing else. Skill bodies and `standing_orders` are prose that
bloats every future prompt and can contradict itself; a routing rule is
numeric, bounded, trivially reversible, and directly measurable. That is the
whole reason it goes first, and alone.

It is off everywhere until an operator sets, per workspace:

    arb config set loop.autonomous_routing_enabled true --workspace <id>

With the flag unset — the default on every workspace including `default` —
routing, the queue, and the config are byte-for-byte what they were before
Stage 3 existed. Unsetting it again is the kill switch and takes effect on the
next dispatch, mid-canary, with no config to unwind.

The kill switch **ends** the canary rather than pausing it: the first tick after
the flag disappears drops the `loop.canary` block. While the flag is off the
overlay is `nil` for every dispatch, so both "arms" are the same arm — if the
block survived, re-arming the flag later would judge a window full of dispatches
the canary never influenced, find the two arms identical (they were), and read
that tie as a pass. Re-enabling starts a clean canary instead.

**What is eligible.** Only a `:proposed` row that has already been escalated to
an operator at least once, whose evidence *still* clears the workspace's bar on
its own terms (a `:task`-scoped row that bypassed the bar by blast radius is
refused — a fleet routing change is not blast-radius 1), whose patch is exactly
one `D<n>` tier's `model_tier`/`thinking` and nothing else, in a workspace that
actually routes `by_difficulty`. The bar is never lowered for autonomy; if
anything the gate is tighter than the operator's own `apply`.

**The canary.** Starting one writes a `loop.canary` block to the workspace
config — **not** `routing.rules`. The candidate rule is overlaid at dispatch
time by `ByDifficulty`, and only for tasks in the canary arm: a stable 50/50
split of task ids salted with the proposal id (`Canary.arm/2`). A task's
`#review` runs hash into the same arm as the task. Alternating dispatches
rather than a repo split, because `Routing.choose/3` is not handed the repo —
the arm has to be derivable from what routing has and from what `worker_runs`
records afterwards, or the application and the measurement would disagree about
who was in which arm.

**The verdict.** No verdict at all before the canary arm has **20** dispatches
(`loop.canary_min_dispatches` may raise that floor, never lower it) and both
arms have a reviewed task. Then first-pass ReviewGate convergence is compared
between the arms:

- **below** control (beyond `loop.canary_regression_tolerance` — a convergence
  fraction in `0..0.5`, default `0.0`, rejected at the config boundary rather
  than silently clamped, because a threshold nobody knows was ignored would
  mask exactly the regression this stage exists to catch)
  → **auto-revert**: the `loop.canary` block is deleted and the proposal is
  soft-rejected with the measurement in `outcome_delta`. Nothing was ever
  written to `routing.rules`, so the revert is a deletion, not a repair;
- otherwise → **promote**: the rule lands on `routing.rules.D<n>` fleet-wide
  and the proposal moves to `applied`.

Cost per review round is reported alongside but never triggers a revert — a
tier change that buys convergence with money is a judgement call, not a
regression.

**The deadline.** A canary that has not gathered its sample within
`loop.canary_max_age_days` (default 14, ceiling 90) **expires**: the block is
dropped, the proposal is soft-rejected with an `outcome_delta` saying how long
it ran and how far it got, and the operator is mailed. A multi-day window is the
design; an open-ended one would leave an unvalidated rule live on half of a
quiet tier's dispatches indefinitely, with no second notice after the start
mail.

An operator who rejects (or applies) the proposal while its canary is still
running has overruled the experiment: the canary is **abandoned** on the next
tick — block dropped, rule not landed — however well the canary arm was doing.
Autonomy never outranks a decision you made.

Both outcomes are a `paper_trail` version on `Workspace` attributed to
`loop:proposal:<id>`, and both post coordinator mail. `Arbiter.Loop.CanaryTicker`
is what makes the revert *automatic*: it walks every workspace on a timer and
judges any running canary. For a workspace with the flag unset it does a single
map lookup and stops.

## Where lessons land (you choose, per finding)

- **A skill** — the primary home for a *general working practice* (read
  discipline for large-corpus tasks; verify-at-runtime before signalling done).
- **The repo's `CLAUDE.md`** — a *repo-specific convention*.
- **A per-task override** — a single incident (blast-radius-1).

Prioritisation note: Haiku is under 2% of total spend, so a perfect
economy-tier fix is a rounding error. The real prize is avoided rework — a large
fraction of reviewed tasks need a round 2.

## Known data limitations (current corpus)

- `review_gate_rounds` is sparse (Stage 0 only recently began recording it), so
  per-task round counts and reviewer-finding clustering are thin. Rounds are
  linked to the *authoring* task by stripping the ReviewGate `#review…` suffix;
  a task with no rounds recorded shows round 1 even when it was rejected (the
  rejection is still caught via the failed run's `failure_reason`). `bd-7rspia`
  is such a case — flagged via its `:review_gate_rejected` run, not a round row.
- `issues.difficulty` is the *current* value, so a re-filed task shows its final
  difficulty, not the value each attempt was dispatched at. Read
  "dispatched difficulty" in the report with that in mind.

## Why it can't run the way the first attempt did

Attempt 1 at this task died of context exhaustion from unbounded reads (a
`find /`, repo-wide greps). The pass is built so the heavy lifting happens in
Elixir (`Arbiter.Loop.Corpus` does bounded, aggregated SQL); the operator's
context sees only the shaped report, never the raw 28 MB corpus. When you act
on the report, keep the same discipline: drill into named `run_id`s with
`arb worker log` / `worker_log`, never whole-corpus reads.

### Transcript read bound (bd-3ozmaj / #1159)

A failed run's `terminal_lines` — what `FailureClassifier` sees — is the union
of two bounded reads, not a raw transcript read:

- the last 40 lines (`OutputLog.tail_lines/2`) — the terminal signal
  (autocompact thrash, `claude session error`, final `arb done`).
- every line matching a narrow infra fingerprint (`OutputLog.scan_for/2`,
  patterns from `FailureClassifier.infra_fingerprints/0` —
  `Phoenix.Ecto.PendingMigrationError`, `DBConnection.ConnectionError`).

The second read scans the *whole* transcript, not just the tail. Attempt 1 at
bd-8mtb0q (#1132) taught the classifier those fingerprints, but the corpus
still only ever showed it the last 40 lines, so a failure that occurred
earlier in a long run (240–2500+ lines, agent kept going after the crash) was
never seen and stayed `unclassified` — verified against the live corpus on
2026-08-09. The fix keeps the tail read for everything else and adds a
full-scan pass restricted to this narrow, unambiguous fingerprint list — safe
because these strings can only come from Arbiter's own infrastructure, so a
whole-file scan carries no false-positive risk, and the corpus is small
(tens of files, single-digit MB). This scan is per-failed-run and its cost
is included in the pass's own `duration_ms` usage-event row.
