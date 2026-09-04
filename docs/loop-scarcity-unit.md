# The loop's unit of scarcity

**Status:** decided, implemented (#1463 / epic #1011 Amendment E).
**Owner module:** `Arbiter.Loop.Scarcity`.

## The problem this settles

Stage 1 of `Arbiter.Loop` was denominated end-to-end in imputed dollars. The
corpus joined `usage_events` for a per-run `cost_usd`; `(difficulty, repo)` cell
comparisons ranked tasks by spend; the difficulty-misestimate cohort test
required a task to exceed its cell median *on cost*; and proposals pre-registered
cost-shaped `target_metric` / `baseline` pairs.

Amendment E of epic #1011 (comment 5224659452) observed that this denominator is
wrong for how this installation actually runs:

> the marginal dollar cost of the next Claude token is zero… what is genuinely
> finite is the 5-hour and 7-day utilization windows

The consequence is not cosmetic. A loop optimising a unit that does not bind can
propose a change that reduces imputed spend while making the binding constraint
worse, and it is *indifferent* to a change that materially relieves it. Every
comparison it makes — including the carefully-constructed cell comparisons — is
weakened by being expressed in the wrong unit.

## Decision 1 — the unit is `window_share_5h`

**A run's draw on one 5-hour utilization window, as a fraction of that window's
capacity.**

### Why 5h and not 7d

The 5h window is the one that actually stalls dispatch here.
`Arbiter.Quota.Gate.Snapshot` normalizes **only** the primary window onto the
provider-neutral gate shape, and its moduledoc is explicit that this
"[matches] the Anthropic gating this generalizes (which keys on the 5h window and
ignores the 7d one)". A metric denominated in the 7d window would describe a
constraint that, on this installation's gating path, never binds.

The 7d figure is not discarded — `Scarcity.calibrate/3` carries `utilization_7d`
on the calibration so a window where the *weekly* limit is the live risk is still
visible to an operator. It is context, not the objective.

### Why a per-run *share*, not observed utilization

Observed utilization cannot be attributed per run, and this is a hard property of
the schema rather than a gap to be filled later:

`Arbiter.Quota.AnthropicQuota` is a **latest-only cache** — one row per
`{workspace_id, provider}`, overwritten in place by an upsert, and its moduledoc
says so ("a cache of the latest reading, not a time series"). A 7-day corpus has
no historical utilization series to join against. There is exactly one
utilization figure in the database, and it describes *now*.

What *is* per-run is the token ledger. `usage_events` carries `tokens_in`,
`tokens_out`, `cache_creation_tokens` and `cache_read_tokens` with an
`occurred_at`, keyed by `worker_run_id`. Window utilization is monotone in
weighted token consumption, so a run's *share* of a window is attributable even
though the window's history is not. That is the derived pressure metric the
ticket's scope left open, and it is the only one the data supports.

### How capacity is estimated

`Scarcity.calibrate/3` divides the fleet's weighted token draw over the
**current** 5h window by the `utilization_5h` the provider reported for that same
window:

```
capacity_weighted_tokens = observed_weighted_tokens / utilization_5h
```

Capacity is a plan constant, so the estimate carries across the corpus window
even though it is measured on the current one. The estimate's inputs
(`observed_weighted_tokens`, `utilization`, `captured_at`) are all rendered in the
report's "Unit of scarcity" table, so an operator can see how it was derived and
how stale it is.

Two things about that division are load-bearing enough to state separately.

**The interval must match on both sides.** `observed_weighted_tokens` is summed
over `[window_start, captured_at]` — not up to `now`. `window_start` comes from
the snapshot's `reset_5h_at`; `captured_at` is when the utilization figure was
read. Letting the numerator run past `captured_at` would divide a longer
interval's draw by a shorter interval's utilization and over-state capacity.

**A stale snapshot cannot calibrate at all.** `anthropic_quotas` is a latest-only
cache, so `Quota.latest/2` returns whatever was captured last, however old. A
reading from a window that has already reset places `window_start` in the past
while its `utilization_5h` describes a window that has since rolled several
times — capacity would come out inflated by roughly the number of elapsed
windows, and every share deflated by the same factor, while the frame still
claimed `:calibrated`. `Arbiter.Loop.Corpus` therefore runs the snapshot through
`Arbiter.Quota.Gate.stale?/1` — the same predicate the dispatch gate refuses to
throttle on (`reset_at` elapsed, or `captured_at` older than 5h) — and treats a
stale reading as an absence, `reason: :stale_snapshot`. It is still used to infer
the *billing mode*: a stale reading is weak evidence about the current window but
perfectly good evidence that this plan has windows at all.

### Coverage: capacity is a lower bound, shares are upper bounds

The numerator of the calibration is *Arbiter's* observed draw; the denominator is
the *account's* reported utilization. Those two populations are not identical, and
the asymmetry runs one way.

The part that is fixable is fixed: both the per-run numerator (`tokens_by_run/2`)
and the calibration's observed draw are read **fleet-wide**, with no
`workspace_id` filter. That matters because some `usage_events` rows legitimately
carry a `nil` `workspace_id` (`Arbiter.Usage.WorkspaceBackfill`), and because
runs from other workspaces still draw on the same account windows. Scoping one
side but not the other would under-count `observed` and inflate every share by
the reciprocal of the coverage ratio — enough to push shares past 100% of a
window.

The part that is *not* fixable from the ledger is traffic that never passes
through Arbiter at all: an interactive Claude Code session on the same plan
raises `utilization_5h` without writing a `usage_events` row, and on this
installation that is the common case rather than an edge case. So:

* `observed` under-counts the account's true draw,
* hence `capacity = observed / utilization` is a **lower bound** on true capacity,
* hence every `window_share_5h` is an **upper bound** on a run's true draw, and a
  share above 100% of a window is a known over-estimate, not a measurement.

The report's calibration line says exactly this, in those words, next to the
capacity figure — the same "absence is never silent" discipline applied to bias
instead of to missing data.

Note what this does *not* undermine. The bias is a single scale factor shared by
every run in the window, so it cancels in every comparison the loop actually
makes — the ranking of tasks within a `(difficulty, repo)` cell, and a subject's
share against its cohort median, are unaffected. It is only the *absolute* share
that must be read as "at most this much of a window". This is a different
argument from the weight-vector one below (which is about a scale error in the
weights cancelling exactly); the two are independent and both are needed.

### The weighting, and why an approximate vector is sound

Anthropic does not publish the token weighting behind the unified windows.
`Scarcity.weights/0` uses the published *pricing* ratios as the proxy — input
1.0, cache-write 1.25, cache-read 0.1, output 5.0 (Sonnet's $3 / $3.75 / $0.30 /
$15 per Mtok).

The obvious objection is that these are the wrong numbers. The answer is that
**only their ratios matter**: capacity is calibrated from the *same* weighting, so
a global scale error appears in numerator and denominator alike and cancels
exactly. Doubling every weight leaves every share unchanged — there is a test
pinning this. What the vector has to get right is the *relative* draw of a cached
read versus an output token, and relative pricing is the best public evidence
available for that.

### Absence is never zero

Every path degrades to `nil`, never to a plausible-looking `0.0`. No captured
snapshot, a snapshot too stale to describe the current window, an idle
calibration window, or a `0.0` utilization reading each yield
`status: :uncalibrated` with a machine-readable `reason`
(`:no_snapshot` / `:stale_snapshot` / `:no_utilization` / `:no_observed_tokens`),
`window_share_5h` of `nil` on every row, and an explicit "**uncalibrated**" line
in the report naming which absence it was. This is
the same discipline `Arbiter.Loop.Corpus` already applies to `transcript_reads`:
a blind window must not read as a clean one.

## Decision 2 — dollars are retained as a secondary metric

Dollar cost is still the right unit under metered API billing, so it is
**ranked, not removed**. Both figures are computed and reported in every window;
`billing_mode` decides which leads.

`Arbiter.Loop.Scarcity.billing_mode/2` resolves it at analysis time rather than
assuming, in three steps:

1. **Configured.** `loop.billing_mode` in workspace config — `"subscription"` or
   `"metered"` → `{mode, :configured}`. An unrecognised value is ignored rather
   than trusted, and falls through to inference.
2. **Inferred.** A captured `AnthropicQuota` snapshot carrying a unified 5h
   utilization figure is direct evidence of a plan with windows →
   `{:subscription, :inferred}`.
3. **Default.** No window evidence at all → `{:metered, :default}`. Dollars are
   then the only unit that is readable, so they lead by necessity.

The verdict *and its source* are rendered in the report, so "subscription
(inferred)" and "metered (configured)" are distinguishable to an operator.

## What actually changed in the analyser

* **Corpus** (`Arbiter.Loop.Corpus`) — each row gains `weighted_tokens` and
  `window_share_5h`; `meta.scarcity` carries the unit, the secondary unit, the
  billing-mode verdict, and the calibration. Two bounded grouped queries, in
  keeping with the module's read discipline.
* **Objective function** (`Arbiter.Loop.Analysis`) — the difficulty-misestimate
  cohort test compares on the binding unit. Under subscription billing a task
  that is *cheaper in dollars* than its cell peers but eats more of the 5h window
  is now flagged; under the old comparison it was invisible. The comparison falls
  back to dollars per-cell when the subject or any peer lacks a share, so units
  are never silently mixed and an uncalibrated install keeps the comparison it
  always had.
* **Cells** — each `(difficulty, repo)` cell reports `mean_window_share_5h`
  alongside `mean_cost_usd`.
* **Pre-registered proposal metric** — the `:rework` misestimate is the
  misestimate that becomes a real `:difficulty_override` `PendingWrite`
  (`Arbiter.Loop.Proposals`), carrying the recommendation's `target_metric` /
  `baseline` pair as its pre-registration. Under subscription billing that pair is
  now quota-denominated: *"5h-window share to converge for `<task>`"*, with a
  baseline of *"12.3% of one 5h window across 2 attempt(s), vs. a 4.1% cell
  median; round-1 approval 0% (first attempt needed 3 rounds)"* — the rounds
  figure retained as the leading indicator it has always been. Under metered
  billing the pair is byte-identical to before.
* **Report** — a "Unit of scarcity" section precedes every number denominated in
  it.

`Arbiter.Loop.PendingWrite.context_cost_tokens` needed no change: Amendment D
already priced a fleet-wide prompt addition in **tokens**, which is the quota
unit, not dollars. It is the one place the loop was already denominated
correctly.

## The analyser's own draw

Amendment E's footnote: an analyser that measures quota windows consumes them
too. Stage 1 is deterministic Elixir — SQL aggregates, bounded transcript reads,
pure formatting, and no model call anywhere — so its draw on the 5h/7d windows is
a **measured zero**, not a rounding-down.

That is written down in two places rather than asserted here:

* `Corpus.record_pass_cost/1` writes explicit `tokens_in: 0` / `tokens_out: 0` /
  `cache_creation_tokens: 0` / `cache_read_tokens: 0` and
  `raw.quota_window_draw: "none"` on the pass's own `usage_events` row.
* Every report renders an "analyser's own draw" note saying the same thing.

Both stop being true the moment an LLM call lands inside `Loop` — the
payload-authoring work the ticket flags. When that happens the draw lands on the
very row above, and the note must stop saying "none". The accounting is already
wired; only the number is currently zero.
