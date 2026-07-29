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
read the report and decide. This mirrors the `report_only` + greenlight
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
Elixir (`Arbiter.Loop.Corpus` does bounded, aggregated SQL and reads only the
*tail* of a failed run's transcript); the operator's context sees only the
shaped report, never the raw 28 MB corpus. When you act on the report, keep the
same discipline: drill into named `run_id`s with `arb worker log` /
`worker_log`, never whole-corpus reads.
