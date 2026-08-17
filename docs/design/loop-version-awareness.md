# Loop version-awareness — design options

Research task `bd-7shbxy` (#1222). **No implementation.** This is the
design-options writeup the task asks for: what `arb loop analyze` should do
with arbiter's own version, given that every release changes the generative
process behind the corpus it reads.

Everything in [What I verified](#what-i-verified) was checked against the
running fleet and this repo on 2026-08-17, not recalled. Every recommendation
below cites the code it would touch.

---

## Verdict, up front

1. **The version is not recoverable per run today, and the release tag is the
   wrong unit anyway.** Stamp `(arbiter_version, arbiter_sha)` on `worker_runs`
   at dispatch. The sha is the real identity of "the fleet that produced this
   run"; the tag is a display rollup of it.
2. **Make it visible before making it block.** A build-composition line in the
   header *and a `builds` column on the cell table* is the whole fix for the
   reported case, costs no behaviour change, and is the diagnostic that tells
   you whether the rest is worth building.
3. **`--propose` should warn, not refuse** — except for one narrow, declarable
   class: a candidate scored on a metric a specific build provably changed,
   whose evidence straddles that build. Downgrade those to `:hypothesis`
   instead of dropping them.
4. **Standing hypotheses: do not decay, do not invalidate, do not partition.**
   Require one corroborating incident from the running build before promotion,
   and render each row's evidence build-composition so the operator's rejection
   is cheap and informed. Never auto-reject — `:rejected` is sticky.
5. **Do not parse changelogs.** Declare the small "this build broke this
   metric" mapping in code, appended by the PR that breaks it.
6. **Baselines: the fix is architectural, not a schema change.** Never build a
   before/after outcome checker at this cadence. Extend `Canary`'s concurrent
   arms, which are immune to the problem by construction.

The highest-risk path is one the issue does not name — see
[finding 4](#4-the-riskiest-path-bypasses-the-evidence-bar-entirely).

---

## What I verified

### 1. There is no version anywhere in the data

No `version` column on `worker_runs` (checked all three resource snapshots in
`apps/arbiter/priv/resource_snapshots/repo/worker_runs/`), none on
`usage_events` or `loop_pending_writes`, and **no releases/deploys table at
all** — the snapshot directory holds 17 tables and none of them record a
deploy. So the version is not recoverable per run, and it is not derivable
from a deploy timeline either, because no deploy timeline is persisted.

The version *is* available at runtime: `Arbiter.Version.app_version/0`,
`git_sha/0` and `built_at/0` (`apps/arbiter/lib/arbiter/version.ex:90-96`),
surfaced by `GET /api/version`. Live response from the running fleet:

```json
{"version":"0.1.56","sha":"4daeac8a",
 "built_at":"2026-08-17T21:49:50Z","booted_at":"2026-08-14T23:29:02Z"}
```

### 2. The release tag is the wrong unit — off by ~13×

The issue frames the problem as releases (8 in two weeks against a 7d window).
The real granularity is worse, and the live response above shows it:

| observation | value |
|---|---|
| release tags in the current 7d window | **2** (`v0.1.55`, `v0.1.56`) |
| first-parent merges to `main` in the same window | **27** |
| commits on `main` past the newest tag | **8** |
| running node's sha | `4daeac8a` — i.e. `v0.1.56 + 8 commits` |
| `built_at` (2026-08-17) vs `booted_at` (2026-08-14) | modules hot-reloaded 3 days into the node's life |

Three independent reasons the tag cannot stand in for "what executed this run":

- **This is a continuous deployment of `main`.** The fleet runs merged commits;
  tagging is a later, separate act. Eight commits of live behaviour change are
  currently labelled `v0.1.56` by any tag-based scheme.
- **Tag time ≠ deploy time.** `v0.1.56` was tagged 2026-08-14T09:55 EDT; the
  issue records the deploy at 14:22. A backfill that maps run timestamps onto
  tag timestamps would mislabel every run in that 4.5-hour band, and the bands
  are exactly where the interesting boundaries are.
- **Hot reload moves the code under a running node.** `built_at` is three days
  after `booted_at`. Even a persisted boot-time version stamp would be wrong.

Release size is also wildly uneven — `v0.1.53..v0.1.54` is 2 commits,
`v0.1.54..v0.1.55` is 24 — so "one version" is not even a consistent quantity
of change. Splitting the current window at its two tag boundaries makes the
point concretely: **28 / 148 / 60 runs**. The middle bucket is 63% of the
corpus in a single tag-labelled bin that actually spans 15 merges — a
composition line built on tags would report that as one homogeneous
population.

**Consequence:** stamp the sha. Carry the version alongside it for human
legibility, and treat any tag-derived or time-derived attribution as
unavailable.

### 3. The straddle is live right now, not a retrospective anecdote

I ran the read-only pass against the fleet on 2026-08-17:

```
$ curl -s "http://localhost:4848/api/loop/analyze?since=7d"
# window 2026-08-10T21:52Z → 2026-08-17T21:52Z, 236 runs, 75 main runs
```

Every fix from the issue's table landed on `main` **inside** this window:

| commit | landed (UTC) | what it changed |
|---|---|---|
| `a55d96df` (#1180) | 2026-08-12T21:21 | slug→`rig_paths` match → `target_branch` → failure classification |
| `7451a0ee` (#1188) | 2026-08-13T02:48 | cost accounting (`usage_summarize` dropped task rows) |
| `495f63b6` (#1197) | 2026-08-13T22:22 | PRPatrol re-dispatch loop → tasks per PR |
| `e20db5ef` (#1206) | 2026-08-14T05:51 | finalize exiting without completing → round counts |
| `29a383f1` (#1207) | 2026-08-14T06:01 | revise-round briefing → round counts |

Splitting the 236-run window at the cost-accounting boundary:

```sql
-- runs in window, split at 7451a0ee (2026-08-13T02:48Z)
pre = 65    post = 171
```

So **28% of the current corpus reports cost under different accounting than the
other 72%**, and the report pools them without saying so.

### 4. The riskiest path bypasses the evidence bar entirely

The issue's Q4 is about hypotheses accumulating across a boundary. That is the
*slow* path. The fast path is worse and unmentioned:

`difficulty_misestimates/1` builds its own `{difficulty, repo}` cohorts
(`analysis.ex:292`) and scores each task against a **cohort median cost**
computed inside `cohort_verdict/3` (`analysis.ex:383` for rework, `:398` for
quality failures) — a task is flagged only if `t.cost > cohort_cost`. That
median is computed over the whole window, so it pools 65 pre-`#1188` runs
(which under-report cost) with 171 post-fix runs. A depressed median makes
post-fix tasks look like cost outliers, and the live report shows 12
misestimates in cell `(2, arbiter)`.

`Analysis.cells/1` (`analysis.ex:485-517`) does *not* feed that test: it pools a
**mean** (`mean_cost_usd`, `analysis.ex:513`) — which is the `$2.61` the report
table renders (`report.ex:209`) — over the same `{difficulty, repo}` grouping of
the same `main_rows`. So the two agree on the population (which is why the
per-cell `builds` column below is measured on the right set), but they disagree
on the statistic, and the number that actually gates a proposal is the cohort
median, which is never rendered.

Those 12 become `:difficulty_override` candidates at `scope: :task`
(`proposals.ex:171-200`), and:

```elixir
# apps/arbiter/lib/arbiter/loop.ex:432
defp clears_bar?(:task, _incidents, _tasks, _bar), do: true
```

**A task-scoped candidate bypasses the evidence bar and lands `:proposed`
immediately.** So the debate about hypothesis decay governs a path that
requires 3 incidents across 2 tasks; the cost-median comparison feeds a path
that requires none. Whatever version-awareness is built, this is where it
earns its keep first.

### 5. `incident_refs` is a heterogeneous key space

Resolving "what build is this evidence from" is not one join:

| candidate source | `incident_refs` contains | code |
|---|---|---|
| reviewer-finding categories | **run ids** (`cat.run_ids`) | `proposals.ex:141` |
| per-task difficulty misestimates | **task ids** (`[m.task_id]`) | `proposals.ex:198` |
| misestimate cluster (`:config_set`) | **task ids** (`task_ids`) | `proposals.ex:248` |

Run ids join `worker_runs.id` cleanly. Task ids fan out to many runs across
possibly many builds. Any design that reads the build of accumulated evidence
has to confront this; see [rung 4](#the-ladder).

### 6. The canary is already immune; the pre-registered baseline is not

`Arbiter.Loop.Canary` measures a change against a **concurrent** untouched arm —
a stable 50/50 split of task ids under the same running build
(`canary.ex:55-66`). Both arms therefore always share a build, and no release
can confound it. This is the correct pattern and it already exists here.

By contrast `PendingWrite.baseline` is a free-text string
(`pending_write.ex:219`) refreshed on every reinforce (`loop.ex:349`). Nothing
computes a delta against it — `outcome_delta` is written **only** by `Canary`
(verified: the only writers are `canary.ex:766/789/824`). So Q6 is a **latent**
problem today, not a live one. It goes live the moment a non-canary outcome
checker is built, which is the reason to settle it now.

---

## Answers

### Q1 — Is the version recoverable per run?

**No, and it must become so. This is the prerequisite for everything else.**

Add two attributes to `Arbiter.Workers.Run`:

```elixir
attribute :arbiter_version, :string   # "0.1.56"  — display rollup
attribute :arbiter_sha,     :string   # "4daeac8a" — the actual identity
```

Stamp both in `Arbiter.Worker.record_run_started/1`
(`apps/arbiter/lib/arbiter/worker.ex:712`), in the same `attrs` map as
`difficulty_at_dispatch`. Values come straight from `Arbiter.Version` — **no
dispatcher plumbing is needed**, unlike `difficulty_at_dispatch` which has to
travel through `state.meta`, because the node executing `record_run_started/1`
*is* the fleet that runs the worker.

This is the `difficulty_at_dispatch` precedent applied verbatim, and that
attribute's own description already states the principle
(`workers/run.ex:315-324`): record what governed the run, not what the current
state of the world says about it. Same argument, same shape, one more
dimension.

**Do not backfill.** `nil` means "predates version stamping", exactly the
convention the provenance fields already use (`workers/run.ex:29-31`). An
approximate backfill from tag timestamps is available and is precisely the
thing [finding 2](#2-the-release-tag-is-the-wrong-unit--off-by-13) shows to be
wrong; a backfill that is confidently wrong is worse than a `nil` that is
honestly absent.

**Free bonus, no migration:** `Corpus.record_pass_cost/1` already writes a
`raw` map with `kind` and `rows_scanned` (`corpus.ex:144-147`). Add
`arbiter_version` / `arbiter_sha` keys so every recorded pass is
self-describing. One map key, zero schema change, and it means the ledger can
answer "which build produced this analysis" retroactively.

### Q2 — What should the report say?

Two things, and the second matters more than the first.

**(a) A header composition line.** In `Report.corpus/1` (`report.ex:78`):

```
**Fleet build:** v0.1.56 (4daeac8a)
**Corpus spans 9 builds** across v0.1.55 (176 runs) and v0.1.56 (60 runs);
top 3: v0.1.56+090c96bc (34) · v0.1.55+d3d75272 (52) · v0.1.55+7451a0ee (31)
```

(Illustrative shape — the exact per-sha counts are not computable until rung 1
lands. The per-version rollup, `176 / 60`, is real: it is the current window
split at the `v0.1.56` tag, and it is exactly the over-coarse binning
[finding 2](#2-the-release-tag-is-the-wrong-unit--off-by-13) warns about.) Render the rollup always and the top-N shas
underneath, because the sha list is long by construction and the version
rollup is what a human scans first.

Plus, when the corpus is entirely older than the running build, one more line —
this alone catches the reported case with no behaviour change:

```
⚠ Every run in this corpus predates the running build (v0.1.56+4daeac8a).
  Findings describe a fleet that is no longer deployed.
```

And when >1 build is present, a note in the same voice as the existing
`@small_sample_caveat` (`analysis.ex:31`), appended to `notes`:

> metrics move with build as well as difficulty mix and repo — cross-build
> comparison reads release effects as fleet drift.

**(b) A per-cell `builds` column, which is the one that would have caught the
live case.** A single global composition line is not enough: the report's
actionable claims are per-cell, and a cell is a much smaller population than
the corpus. `cells/1` already groups by `{difficulty, repo}`
(`analysis.ex:502`); add the count of distinct builds among the pooled tasks.
A cell with `builds: 1` is internally comparable. A cell with `builds: 3` is
where its statistics are suspect — and cell `(2, arbiter)` above, with its
`$2.61` rendered mean, the unrendered cohort median behind it, and 12
misestimates hanging off that median, is exactly that.

Mechanically this requires `Corpus.base_runs/3` to select the two new columns
(`corpus.ex:162-173` currently selects neither them nor `started_at`) and
`Corpus.fetch/1` to carry them onto each row.

Also surface `builds: N` in `summary/1`
(`arbiter_web/.../api/loop_controller.ex:191`) so `--json` consumers see it
without parsing markdown.

### Q3 — Should `--propose` refuse or warn when the window straddles a release?

**Warn by default. Refuse — narrowly and by downgrade, not by dropping — in
exactly one declarable class.**

Refusing on "the window straddles a release" refuses essentially always: 27
merges in the current 7d window means every practical window straddles
something. That is the issue's own stated non-goal, and it is the right call.

The defensible narrow rule is not about the *window*, it is about the
*candidate*: a candidate is untrustworthy when the metric that justifies it is
a metric a specific in-window build provably changed. Today that is one rule:

> A `:difficulty_override` or `:config_set` candidate justified by a **cost**
> comparison — i.e. against the cohort median in `cohort_verdict/3`
> (`analysis.ex:383/398`) — whose cohort pools runs from both sides of a
> cost-accounting build, is recorded as `:hypothesis` rather than
> `:proposed` — i.e. it is denied the
> `:task`-scope bar bypass at `loop.ex:432` — with the reason recorded on the
> row.

It is downgraded, never dropped: the evidence still accumulates, and one clean
post-build window promotes it normally. Rounds-justified rows are untouched,
because no in-window build changed how rounds are counted for *them*
specifically — which is a claim the [Q5](#q5--can-a-releases-changelog-inform-the-pass)
mapping makes checkable rather than assumed.

Add `--allow-mixed-build` to `arb loop analyze --propose` as the operator escape
hatch — the generative path, i.e. the flag on `analyze` (`cmd/loop.ex:19`, routed
to `POST /api/loop/propose` at `cmd/loop.ex:141-147`), not the separate
`arb loop propose repo-doc-patch` verb (`cmd/loop.ex:82-86`), which is an
operator-authored lesson and never runs the analysis pass.
The operator is in the loop by design; the job here is to make them see it, not
to make the decision for them.

### Q4 — What happens to standing hypotheses at a build boundary?

*The part the issue most wants answered.* The recommendation is deliberately
conservative: **make the evidence's build composition visible, add one weak
liveness condition on promotion, and change nothing else.**

**Rejected: partition hypotheses by version.** This means adding version to
`Loop.fingerprint/1` (`loop.ex:141`), whose docstring already explains why
everything that accumulates is excluded: including it "would make every window
a fresh fingerprint and defeat the mechanic". At 27 builds/week, partitioning
gives every hypothesis a population of one, forever. It does not weaken the
accumulation mechanic — it deletes it. Reject outright.

**Rejected: time-decay of confidence.** Age is the wrong axis. What invalidates
an incident is a change to *the code path that produced it*, and those two are
only loosely correlated. A hypothesis about reviewer prose quality is untouched
by 27 merges to the PR poller; decay penalises it identically to one about cost
accounting. Decay is a proxy that is easy to implement and wrong in a way that
is hard to notice.

**Rejected: invalidate refs older than the current build.** The issue's own
non-goal, and correctly so — at this cadence it discards nearly all evidence on
nearly every release.

**Recommended, two parts:**

**(a) Promotion requires ≥1 incident ref from the running build.** At the
`:hypothesis → :proposed` transition (`loop.ex:328-331`), additionally require
that at least one incident ref resolve to a run on the currently running build.

This is a liveness condition, not an invalidation. It costs a genuinely live
problem nothing — a live problem recurs, that recurrence *is* what makes it
live — and it kills the pure fossil: a hypothesis whose incidents all predate
the running build never promotes on its own, no matter how many it has
accumulated. It never destroys evidence, and it self-heals the moment the
problem reoccurs.

**A caveat worth stating plainly:** this does *not* fully solve the issue's
#1197 example. There, a hypothesis built from three pre-fix duplicate
dispatches is pushed over the bar by "a fourth incident of unrelated origin" —
and that fourth incident *is* current-build, so (a) still promotes it. But that
failure is a **fingerprinting** problem, not a version problem: an incident of
unrelated origin should carry a different `category`, and therefore a different
fingerprint. That it does not is a consequence of coarse bucketing in
`bucket_finding/1` (`analysis.ex:259`). Version-awareness cannot fix coarse
bucketing, and a design that claims it can is overselling. What version
awareness *can* do about it is part (b).

**(b) Render the build composition of the refs wherever a human decides.** On
the escalation post, on `arb loop pending`, on the LiveView detail. The
operator sees:

```
evidence: 5 incidents — 4 from builds ≥3 releases old, 1 current (4daeac8a)
```

and rejects it in one glance instead of reconstructing the history. The
operator's judgement is the real filter here; version-awareness's job is to
make that judgement cheap and informed, not to automate it away.

**Explicitly do not auto-reject on version grounds.** `:rejected` is sticky by
design — a rejected row keeps accumulating evidence but is deliberately never
re-proposed (`loop.ex:333-337`). An automated version-based rejection would be
unusually hard to undo, and would silently suppress a real recurring problem
that happened to be quiet across one build. Keep the sticky state a human act.

**On staleness:** a hypothesis with zero refs from the last N builds is stale
rather than wrong. Do **not** add a state for it — `:superseded` means
replaced, and a sixth state is more machinery than the problem warrants. Expose
it as a derived filter (`arb loop pending --stale`) for a periodic human sweep.

**The cost of (a) and (b)** is that evidence refs must resolve to a build, and
[finding 5](#5-incident_refs-is-a-heterogeneous-key-space) says they do not
uniformly. Recommend normalising new refs to a tagged form — `"run:<uuid>"` /
`"task:<id>"` — tolerating bare strings as legacy (bare uuid → run, else task).
`incident_refs` stays `{:array, :string}`, so this is a value-format change
with a legacy fallback, not a migration. Task-id refs resolve to the build of
their most recent run in the window.

### Q5 — Can a release's changelog inform the pass?

**Yes, and it is not over-engineering — but invert the direction. Do not parse
changelogs.**

Changelog prose → metric impact is an NLP problem that fails silently and
plausibly: a missed mapping looks identical to "nothing broke". Instead declare
the mapping in code, appended by the same PR that breaks the metric:

```elixir
defmodule Arbiter.Loop.Comparability do
  @moduledoc "Builds after which a named metric is not comparable with before."

  @breaks [
    %{sha: "7451a0ee", at: ~U[2026-08-13 02:48:02Z], breaks: [:cost],
      why: "usage_summarize dropped task rows (#1188)"},
    %{sha: "495f63b6", at: ~U[2026-08-13 22:22:18Z], breaks: [:task_volume],
      why: "PRPatrol re-dispatch loop (#1197)"},
    %{sha: "e20db5ef", at: ~U[2026-08-14 05:51:35Z], breaks: [:rounds],
      why: "finalize exited without completing (#1206)"},
    %{sha: "29a383f1", at: ~U[2026-08-14 06:01:46Z], breaks: [:rounds],
      why: "revise-round briefing strengthened (#1207)"},
    %{sha: "a55d96df", at: ~U[2026-08-12 21:21:07Z], breaks: [:failure_class],
      why: "forge-qualified slug vs bare rig_paths key (#1180)"}
  ]
end
```

Four properties make this worth its (small) upkeep:

- **It fails loudly.** A missing entry is a missing entry — reviewable in the
  PR that should have added it — not a hallucinated match.
- **It is what makes Q3's refusal narrow.** Without it, "does this build change
  this metric" is a guess, and the only safe guess is the blunt one.
- **It is what makes pooling the default.** Only metrics named in `breaks` are
  treated as incomparable across that boundary; everything else pools freely.
  The mapping's job is to *permit* comparison, not to forbid it.
- **It is small and mostly static.** Five entries cover two weeks of the fastest
  release cadence this project has had.

The list above is not hypothetical — those five shas are the issue's own table,
recovered from `git log` and cross-checked against the PR numbers it cites.

Optional, flag as nice-to-have rather than required: a CI check that a PR
touching cost computation or `review_gate_rounds` adds an entry.

### Q6 — Should there be a version-aware baseline?

**Yes, but the fix is architectural, and it is cheaper to assert now than to
retrofit.**

Two parts:

**(a) Stamp the baseline string with the build it was measured on.** At record
time, append `" (measured on v0.1.56+4daeac8a)"` to `baseline`
(`loop.ex:292`, refreshed at `:349`). No schema change — it is already free
text, and it is already refreshed on reinforce, so it stays honest.

**(b) The real answer: do not build a before/after outcome checker at all.** At
27 builds/week, any pre/post comparison of a pre-registered baseline against a
later outcome attributes the intervening releases to the proposal. That is a
false-positive generator for the loop's measurement of its own effectiveness —
the worst possible place for one, because it is the mechanism that is supposed
to catch the loop being wrong.

The project already has the right answer built:
[finding 6](#6-the-canary-is-already-immune-the-pre-registered-baseline-is-not)
— `Canary`'s concurrent 50/50 arms share a build by construction, so no release
can confound them. **Recommend adopting this as a standing constraint: any
future outcome measurement extends `Canary`'s arm mechanism to a new proposal
kind, rather than adding a pre/post checker.** Recording that constraint now,
while `outcome_delta` has exactly one writer, is close to free; discovering it
after a second writer exists is not.

---

## The ladder

Cheapest-first, with the dependency order that actually holds.

| rung | what | cost | unblocks |
|---|---|---|---|
| **1** | `arbiter_version` + `arbiter_sha` on `worker_runs`, stamped at `record_run_started/1`; version/sha into `record_pass_cost/1`'s `raw` map | one migration, ~20 lines | everything |
| **2** | Header composition line + entirely-predates warning + **per-cell `builds` column** + cross-build caveat note + `builds` in the JSON summary | read-only, no behaviour change | the diagnostic |
| **3** | `Arbiter.Loop.Comparability` + narrow `--propose` downgrade for cost-justified mixed-build candidates + `--allow-mixed-build` | small, declarative | Q3 |
| **4** | Ref normalisation (`run:` / `task:`) + promotion liveness condition + build composition on escalation / `arb loop pending` | the largest piece | Q4 |
| **5** | Standing constraint: outcome measurement stays concurrent-arm | a doc paragraph + a moduledoc note | Q6 |

**Recommendation: build rungs 1 and 2, then stop and re-run the pass over a
real window before committing to 3 and 4.** Rung 2 is not just a nicety — it is
the measurement that tells you how much rungs 3 and 4 are actually worth. Right
now the honest answer to "how often does a mixed-build cell change a
recommendation" is unknown, and rung 2 is what makes it knowable. Building 3
and 4 first would be optimising against an unmeasured quantity, which is the
same error the issue is about.

Rung 5 is a paragraph and should land with rung 1 regardless of the rest.

## Deliberately not recommended

| option | why not |
|---|---|
| version in `Loop.fingerprint/1` | deletes the accumulation mechanic at this cadence (Q4) |
| time-decay of hypothesis confidence | age is a proxy for the wrong thing (Q4) |
| invalidate refs older than the running build | the issue's own non-goal; discards nearly everything |
| auto-reject fossilised hypotheses | `:rejected` is sticky and near-irreversible (`loop.ex:333`) |
| LLM changelog → metric-impact inference | fails silently; declare it in code instead (Q5) |
| hard refusal of `--propose` on any straddle | refuses ~always at 27 merges/window (Q3) |
| backfill version from tag timestamps | tag time ≠ deploy time; confidently wrong beats honestly `nil` (Q1) |
| a new `:stale` proposal state | a derived filter covers it; a sixth state does not earn itself (Q4) |

## Open questions for the operator

1. **Is `main`-as-deployed the intended model?** The whole "sha not tag"
   argument rests on it. If production is meant to run tagged releases and the
   dev box merely doesn't, the stamp is still right but the composition line
   gets much quieter in production.
2. **Should the CI lint in Q5 be mandatory?** It is the difference between the
   `Comparability` list being reliable and being best-effort. Recommend
   best-effort first — a stale list still beats no list.
3. **Rung 4's promotion liveness condition changes when hypotheses promote.**
   That is a behaviour change to a mechanism currently tuned by
   `loop.evidence_bar`. Worth deciding whether it should be config-gated
   (`loop.require_current_build_corroboration`, default off) for one release
   before becoming unconditional.
