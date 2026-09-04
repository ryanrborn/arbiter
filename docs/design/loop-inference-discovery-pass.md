# Loop inference-based discovery pass — decision record

Task `bd-5oh1lc` (#1464). **Decision only — this ticket requires no code
change**, and the only file it adds besides this one is the throwaway
measurement instrument in `scripts/measure_loop_finding_residue.sh`.

Everything in [What I measured](#what-i-measured) was measured against the
running fleet on 2026-09-04, not recalled. Every recommendation cites the code
it would touch.

Decided together with `bd-4xc69o` (#1460, *authoring* payloads) as the ticket
asks; the interaction is recorded in [§8](#8-interaction-with-bd-4xc69o-and-bd-69gk52).

---

## Verdict, up front

1. **Yes — build a discovery pass.** The ceiling the ticket hypothesises is not
   hypothetical: **81.8%** of reviewer finding units in the last 30 days match
   none of the four `@finding_buckets` regexes and are discarded, uncounted,
   by `Enum.reject(&is_nil/1)` at `analysis.ex:246`. The analyser has produced
   exactly **four** finding categories in its entire life, and the queue proves
   it — the four live `:skill_patch` rows are one per bucket.

2. **The ticket's timing premise is wrong, in the direction that favours
   building.** "The fleet is currently idle with a thin corpus" does not
   survive measurement: the last 30 days hold 1434 runs over 932 distinct
   tasks, 246 of them failed. Corpus volume is not the binding constraint.
   Detector expressiveness is.

3. **The model's output unit is a candidate *detector*, not a candidate
   finding.** This is the one design move that matters. It *dissolves*
   tensions 1 and 2 instead of mitigating them: an LLM-written regex, once a
   human merges it into `@finding_buckets`, is deterministic code, and every
   finding it yields is fingerprinted, reinforced and counted by machinery
   that is unchanged and still contains no model call.

4. **The bounded slice is the residue, not the corpus.** The pass reads the
   finding text the deterministic pass already threw away — never transcripts.
   The entire 30-day residue is 275 units / ~33k tokens raw, ~19k truncated.
   One call, one window, no file reads: the shape that killed attempt 1
   (`c88c77b0`, `corpus.ex:14-21`) is structurally unreachable.

5. **First iteration is zero writes, and Stage 0 has no model in it at all.**
   Stage 0 counts and reports the residue deterministically. It is the
   calibration baseline, and it is worth shipping whether or not Stage 1 ever
   does.

6. **Trigger, in corpus volume:** Stage 0 is unblocked now (it measures what
   already exists). Stage 1 is authorised when Stage 0 reports **≥150 residue
   units across ≥30 distinct tasks in a 30-day window, for two consecutive
   windows**. Today's biased sample already shows 275 across 53 — so the
   expectation is that Stage 0's first two full-corpus windows clear it.

7. **Propose/dispose: adopted, and moved one level up.** The disposing step is
   not a runtime check against the corpus — it is a human merging a PR, after
   which the corpus check is the ordinary deterministic pass. The model's
   words never reach a `PendingWrite`, not even indirectly.

---

## What I measured

Measured 2026-09-04 against the live installation (`localhost:4848`) with
`arb loop analyze --since 30d --json`, `arb loop pending --json`, and
`scripts/measure_loop_finding_residue.sh` (added by this ticket; method below).

### Corpus volume — not thin

| metric | last 30d |
|---|---|
| dispatches | 479 |
| runs | 1434 |
| completed | 1186 |
| failed | 246 |
| distinct tasks | 932 |

### The deterministic pass's blind spots, both measured

| blind spot | size | where it is dropped |
|---|---|---|
| reviewer findings matching no `@finding_buckets` regex | **275 of 336 units (81.8%)**, across 53 tasks | `analysis.ex:246` — `bucket_finding/1` returns `nil` and the unit is rejected, uncounted and unreported |
| failures whose `failure_reason` matches no allowlist entry | **43 of 246 runs (17.5%)** | already surfaced, correctly, as the report's "Unclassified (corpus-integrity signal)" section |

The asymmetry is the whole finding. The failure-reason allowlist **already has
a residue instrument** — `:unclassified` is reported as a first-class
corpus-integrity signal, with citations, precisely so classifier drift cannot
hide. The finding-bucket allowlist has **none**: its residue is four times
larger in proportion and is silently discarded. Nothing in the report, the
queue, or `meta` says the number 275 exists.

That is the single strongest argument in this document, and it is an argument
for a *deterministic* instrument first.

### The queue, as further evidence of the ceiling

| state | rows | kinds |
|---|---|---|
| `:proposed` | 20 | 14 `difficulty_override`, 3 `config_set`, 3 `skill_patch` |
| `:hypothesis` | 4 | 3 `config_set`, 1 `skill_patch` |
| `:applied` | 8 | 8 `difficulty_override` |

Every `:skill_patch` and `:config_set` row in the queue is one of the four
buckets or a `(from, to, repo)` difficulty cluster. The analyser has never once
proposed a change for a problem outside that fixed list — not because the
corpus lacks them, but because it cannot see them.

### Method, and its bias

`scripts/measure_loop_finding_residue.sh` takes the task ids the analyser's own
report names for a window, pulls their `review_gate_rounds` over
`GET /api/review_gate_rounds`, re-implements `Corpus.split_findings/1`
(`corpus.ex:279-293`) and `Analysis.bucket_finding/1` (`analysis.ex:276-280`)
in Python, and counts the units that bucket to `nil`. It considers only
`role: "review"` rounds whose verdict is not `approve`, and drops
`VERDICT: APPROVE` disposition preambles that `split_findings/1` would
otherwise emit as pseudo-units.

The sample is **biased toward tasks the report already surfaced** — i.e. tasks
that had at least one *bucketed* finding. That biases the measured residue
rate **downwards**: 81.8% is a lower bound on the full corpus. Stage 0 replaces
this instrument with an in-Elixir count over the same rows the corpus already
fetches, so the number stops being a sample.

### The determinism claim, re-verified

`Arbiter.Loop.*` remains deterministic end to end. No HTTP client
(`Req`/`Finch`/`Tesla`/`:httpc`), no provider module, no model call: the
outbound alias set across `loop.ex` and `loop/*.ex` is exactly `Repo`,
`Tasks.{Issue, Workspace}`, `Messages.Message`, `Agents.Routing`, `Quota`,
`Worker.OutputLog` and `Loop`'s own submodules. Transcripts are read as text
and never sent to a model. The design below **preserves this property
unconditionally** — see §2.

---

## The decision

### 1. Build, or not

**Build.** The argument in the ticket is sound and the measurement makes it
concrete: a detector allowlist cannot find what nobody anticipated, and 81.8%
of the reviewer-finding signal is currently on the wrong side of that line.

But "build a discovery pass" is decided here as three staged things, and only
the middle one contains a model:

| stage | what it is | model? | writes? |
|---|---|---|---|
| **0 — residue instrument** | count the unbucketed units, report the count and a bounded sample, expose it in `meta` | no | no (the existing cost row only) |
| **1 — discovery report tier** | one model call over the residue, emitting *candidate detector* proposals into a report section | yes | no |
| **2 — detector admission** | a human merges an accepted candidate into `@finding_buckets` as code; the deterministic pass then does everything else | no (a human reviews a PR) | ordinary `PendingWrite` rows, from deterministic code |

Stage 0 is worth shipping on its own merits regardless of what happens to
Stage 1. It closes an asymmetry that is a defect in its own right: the
analyser reports its failure-classifier's drift and hides its
finding-classifier's.

### 2. Tension 1 — fingerprint stability

**Resolution: the model never produces a finding, so it never produces a
fingerprint. It produces a candidate detector.**

The ticket's candidate resolution (discover freely, bin into a controlled
vocabulary, escape-hatch novel categories to a human) is rejected — not
because it is wrong, but because it is strictly weaker than the alternative
for the same human cost:

* Binning at write time still puts a model in the path that produces the
  `category` string that feeds `Loop.fingerprint/1` (`loop.ex:145`). The
  binning step is itself a model judgment, and a model that bins the same
  finding into `missing test coverage` one window and
  `regression in existing behaviour` the next reintroduces exactly the
  instability the vocabulary was supposed to prevent.
* It also requires new machinery: a vocabulary resource, an admission
  workflow, an escape-hatch state, and a rule for what happens to rows whose
  category is later admitted or renamed.

Emitting detectors instead needs **no new machinery at all**:

1. The model reads the residue and proposes, say,
   `{~r/memoi[sz]ation key|memo key|cache key omits/i, "stale memoisation key"}`
   together with the residue units it claims to match and a one-line rationale.
2. A **deterministic** pre-check runs the proposed regex over the window's
   residue, and over the last N windows' residue, before the candidate is
   shown to anyone. A candidate that does not match what the model said it
   matches is dropped, with the discrepancy reported — the same
   corroborate-the-label discipline `FailureClassifier` already applies to
   `failure_reason` (`failure_classifier.ex:28-54`).
3. A human reviews it as a PR adding one tuple to `@finding_buckets`.
4. From merge onward it is ordinary deterministic code. Findings it produces
   get a `category` that is a compile-time constant, therefore a stable
   fingerprint, therefore working cross-window reinforcement — with
   `pending_write.ex:34`'s "never an LLM comparison" still literally true.

The controlled vocabulary is `@finding_buckets` itself. It already exists, it
is already the fingerprint input, and its growth is already a reviewed act,
because it is source code. The escape hatch is a pull request.

**Cost of this choice:** a novel pattern cannot be surfaced as a proposal in
the same window it is discovered — it takes a human merge first. That is
deliberate. The alternative buys same-window latency by putting model text
into the digest that the entire evidence mechanic rests on.

### 3. Tension 2 — correlated model judgments and the evidence bar

**Resolution: model judgments never enter the evidence count. At all.**

The bar (`≥ @min_incidents` incidents across `≥ @min_tasks` tasks,
`analysis.ex:38-39`) continues to count only incidents produced by
deterministic matching over corpus rows. After a detector is merged, its
incidents are re-derived by the same code path that produces every other
finding category today, over the same rows — so three incidents are three
genuine independent observations, exactly as the bar's wording claims. Three
correlated hallucinations cannot become three incidents because the model's
hits are never counted as incidents in the first place.

Two supporting rules:

* **Backfill on admission.** A newly merged detector is run over the retained
  historical residue, so its first `PendingWrite` carries measured evidence
  rather than accumulating from zero. This is the reason Stage 0 must
  *retain* the residue (see §4), not merely count it.
* **A candidate detector must earn its place deterministically.** Before it is
  shown for review, its regex must match ≥ the evidence bar's own thresholds
  when applied to history — ≥3 units across ≥2 distinct tasks. A pattern the
  model finds compelling but that matches one unit is not proposed. The
  model's confidence contributes nothing anywhere in this pipeline.

This also disposes of a subtler version of the risk the ticket names: a model
that reads its own previous window's report and re-asserts the same finding
cannot inflate anything, because reports are not evidence.

### 4. Tension 3 — the bounded slice, and what the bound rules out

**The slice: the finding residue, and only the finding residue.**

Concretely, Stage 1 reads a list of strings, each being one unbucketed unit
from `split_findings/1` for a `role: "review"`, non-`approve` round in the
window, each truncated to 400 characters, capped at N units per window
(default 300, sorted newest-first), tagged with `{task_id, run_id}` for
citation. Measured on the last 30 days: 275 units, 133 712 characters, ~33k
tokens raw and ~19k after truncation. Median unit is 280 characters; p90 is
973; the 5120-character maximum is why truncation exists.

Three properties make this the right bound, and they are the reason it is not
merely "40 lines but more of them":

* **It is a database read, not a file read.** `review_gate_rounds.findings` is
  a column. There is no `OutputLog` call, no directory scan, no unbounded
  walk. The failure mode that killed attempt 1 needs an unbounded read to
  exist; this slice has none.
* **It is pre-summarised prose.** Every unit is a reviewer model's own written
  finding — the highest signal-per-token text in the corpus. Raw transcripts
  are the opposite.
* **It is exactly the complement of what the deterministic pass sees.** The
  pass cannot spend its budget re-reporting what `@finding_buckets` already
  catches, because those units are excluded by construction. Every token buys
  something the existing pass provably cannot produce.

**What this bound rules out finding — stated explicitly, as the ticket asks:**

* **Anything a reviewer never wrote down.** Work that passed review but was
  wrong; work no reviewer looked at. The pass is blind to silent success.
* **Anything inside transcript bodies.** Tool-use loops, thrash patterns,
  wasted turns, misread instructions, an agent doing the wrong thing
  confidently for an hour. All invisible.
* **Temporal, cross-task and throughput patterns.** "Failures cluster after
  deploys", "D3 tasks in `vstim` regressed this week", "the same file is
  touched by three tasks a week". Residue units carry no time series and the
  slice is one window.
* **Cost and quota patterns.** No `usage_events` in the slice; that is
  `bd-69gk52`'s territory and should stay there.
* **Operational failures.** Correctly — they are excluded upstream and must
  stay excluded from prompt-shaping (`failure_classifier.ex:9-19`).

If a later stage wants any of those, it is a different slice and a different
decision. This document authorises exactly one.

### 5. Propose / dispose

**Adopted, with the disposing step moved up a level.**

The ticket proposes: model emits candidate findings → deterministic check
verifies each against the corpus → fingerprint → queue. That is right in
spirit and this design keeps the spirit while making the boundary sharper:

| ticket's shape | this decision |
|---|---|
| model proposes a **finding** | model proposes a **detector** |
| code verifies the finding against the corpus | code verifies the detector against history, *and* a human merges it |
| verified finding earns a fingerprint | the merged detector's output earns a fingerprint, from deterministic code |

The trust model is unchanged from what the analyser already does — corroborate
model-authored labels against the corpus rather than trusting them
(`failure_classifier.ex:28-54`) — and it is applied one level earlier, where
it is cheaper to check and where a wrong answer costs a rejected PR instead of
a polluted queue.

### 6. Zero writes first

**Yes. Explicitly decided: the first iteration writes nothing.**

Stages 0 and 1 both write nothing but the existing `usage_events` cost row
(`corpus.ex:186`). No `PendingWrite`, no skills, no config, no overrides. This
is #1011's Stage 1 discipline applied to an unproven capability, and it is
what lets the first iteration sidestep tensions 1 and 2 entirely.

Stage 1 must additionally be **opt-in and off by default** — an
`arb loop analyze --discover` flag, in the same shape as the existing
`--propose`, so that the default `arb loop analyze` remains byte-identical,
deterministic, and free.

Stage 2 is authorised only after an operator has read Stage 1's report section
for **at least four windows** and judged the candidates useful. Nothing in
this document authorises Stage 2 to be built before that judgment exists.

### 7. Trigger, in corpus volume

* **Stage 0:** no trigger. It measures what already exists and is unblocked
  now. Its cost is a `GROUP BY` and a report section.
* **Stage 1:** authorised when **Stage 0 reports ≥150 residue units across ≥30
  distinct tasks in a 30-day window, in two consecutive windows.** Two windows
  because one window's residue could be a single reviewer's verbosity; two
  makes it a property of the corpus.
* **Stage 2:** authorised when an operator has read four Stage 1 report
  sections and at least one candidate detector has been merged by hand and
  produced findings that the operator agrees are real.

A **stop condition**, deliberately symmetric: if Stage 0's residue rate falls
below 30% — because merged detectors have absorbed the recurring patterns —
Stage 1 has done its job and should be reconsidered rather than kept running.

### 8. Interaction with `bd-4xc69o` and `bd-69gk52`

Both discovery and authoring cross the LLM-in-Loop line, and the ticket asks
that they be decided together. This decision constrains, but does not
determine, `bd-4xc69o`:

* **They can be answered differently, and this one should land first.**
  Discovery here is bounded by a slice that already exists in a column, and
  its output is reviewed as source code. Authoring writes prose into a row
  that an operator applies. The risk profiles are genuinely different, and
  this design's safety rests on a property — the model's output being code a
  human merges — that authoring cannot borrow.
* **If `bd-4xc69o` chooses deterministic templates (its option b), nothing
  here conflicts.** If it chooses an LLM authoring pass (option a), the two
  should share one opt-in flag surface and one cost-accounting path rather
  than growing two.
* **Quota draw (`bd-69gk52`):** Stage 1's draw is one call per pass over a
  slice capped at ~20k input tokens, at the operator's analysis cadence
  (weekly today). It must be recorded through the existing
  `Corpus.record_pass_cost/1` under a distinct step label so it is visible in
  the ledger it optimises, and its 5-hour-window draw must be reported
  alongside its dollar cost once `bd-69gk52` lands the unit. Stages 0 and 2
  draw nothing. While `--discover` stays off by default, the "the analyser's
  own quota draw is negligible while `Loop` stays deterministic" note in
  `bd-69gk52`'s acceptance remains true for the default path.

---

## Rejected alternatives

| alternative | why rejected |
|---|---|
| **Do nothing; the deterministic pass has not hit its ceiling** | Measurably false. 81.8% residue, four categories ever, and a queue whose only applied rows are difficulty overrides. |
| **Model bins findings into a controlled vocabulary at write time** (the ticket's own candidate) | Strictly weaker than proposing detectors, for the same human cost: it keeps a model judgment inside the fingerprint input, needs a new vocabulary resource plus admission workflow, and re-binning drift reintroduces the instability it was meant to prevent. |
| **Model reads transcripts and reports what it notices** | This is attempt 1's shape (`corpus.ex:14-21`). Unbounded, low signal density, and it would largely rediscover what `stop_category` already types. |
| **Model writes `PendingWrite` rows directly, with a confidence score** | Confidence is not evidence. It would make the bar's "3 incidents" mean three correlated model outputs, which is precisely the failure the ticket names. |
| **Skip Stage 0, go straight to the model** | Then nothing knows how big the blind spot is, no baseline exists to judge Stage 1's output against, and there is no retained residue to backfill a merged detector over. |
| **Auto-merge accepted detectors** | A regex merged without review is a fleet-wide behaviour change authored by a model, with no paper trail outside the analyser. The whole design rests on that merge being a human act. |

---

## Implementation issues

Filed by this ticket; see the References section of the PR for ids.

1. **Stage 0 — finding-residue instrument** (no model, no new writes).
   Count units that `bucket_finding/1` rejects, carry the count in
   `Corpus.fetch/1`'s `meta` alongside `failed_runs` / `transcript_reads`, add
   a report section mirroring the existing "Unclassified (corpus-integrity
   signal)" section, and retain the residue units so a later merged detector
   can be backfilled over them. Symmetry with the failure-reason residue is
   the acceptance test.
2. **Stage 1 — `--discover` report tier** (model, zero writes). Blocked on
   Stage 0's trigger. Bounded residue slice, candidate *detectors* only,
   deterministic pre-check of every proposed regex against history before it
   is shown, own cost recorded through `record_pass_cost/1`, off by default.
3. **Stage 2 — detector admission workflow** (no model). Blocked on four
   operator-read windows of Stage 1. The mechanics of taking an accepted
   candidate to a merged `@finding_buckets` tuple and backfilling it.
