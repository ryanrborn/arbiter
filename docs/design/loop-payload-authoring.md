# Loop patch-payload authoring — decision record

Task `bd-4xc69o` (#1460). **Decision only — this ticket requires no code
change**, and the only file it adds is this one.

Everything under [What I measured](#what-i-measured) was measured against the
running fleet on 2026-09-04, not recalled. Every recommendation cites the code
it would touch **by definition** — module, function or module attribute — not by
line number, so the citations survive the next merge of `main` into whatever
branch carries the follow-up work. Bare line numbers appear only for `@moduledoc`
prose, which has no name to cite.

Decided alongside `bd-5oh1lc` (#1464, *discovery*), as both tickets ask. That
ticket's [§8](loop-inference-discovery-pass.md) said this one "can be answered
differently"; it is. Discovery admits a model behind a human merge gate;
authoring admits no model at all.

---

## Verdict, up front

1. **No LLM in `Loop`. Option (a) is declined.** Not on principle — on the
   measurement below, which shows the deterministic path covers every live row
   in the queue and the model's only unique contribution would be one English
   sentence per finding category, of which there are five, hard-coded, in one
   file.

2. **The ticket names one problem; there are three, with three different
   answers.** Treating `skill_patch` / `repo_doc_patch` / `config_set` as a
   single "payload authoring" question is the thing to reject first:

   | kind | live rows | the actual blocker | decision |
   |---|---|---|---|
   | `config_set` | 6 (3 `:proposed`, 3 `:hypothesis`) | none — the payload already carries every input the patch needs | **(b)**, a table lookup |
   | `skill_patch` | 4 (3 `:proposed`, 1 `:hypothesis`) | attribution, then content | **(c) + (b)**, in that order — (c) alone does not apply |
   | `repo_doc_patch` | 0, ever | the analyser cannot emit one; the branch is unreachable | **neither** — nothing is being generated to fix |

3. **`config_set` is the highest-value slice and it is a table lookup.** The
   cluster payload already carries `{from_difficulty, to_difficulty, repo}`
   (the `"cell"` entry written by `Proposals.misestimate_cluster_candidates/3`,
   `proposals.ex`). The patch is
   `routing.rules.D<from> => effective_rule(workspace, to)` — resolved from
   `ByDifficulty.default_mapping/0` merged under the workspace's own
   `routing.rules`. No prose, no attribution problem, no model. All **6/6**
   live rows resolve to a real, non-identity patch on their own workspace
   today.

4. **That slice also unblocks machinery that is already shipped and currently
   unreachable.** #1187's autonomous-routing canary (`Loop.Canary`) consumes
   exactly one shape: a `:config_set` whose patch is one `D<n>` tier's
   `model_tier` / `thinking` (`Canary.parse_routing_patch/1`, `canary.ex`).
   **Nothing in production code produces that shape.**
   `parse_routing_patch/1` rejects every `:config_set` row that exists. The canary's only producers are in
   `test/`. This is not a "would be nice" — an entire Stage 3 feature is
   sitting behind a missing seven-line function.

5. **The fingerprint argument in the ticket is real but points the other
   way.** `payload` is **not** a fingerprint input (`Loop.fingerprint/1`,
   `loop.ex`; the digest is `{kind, target, category, difficulty, repo}`). So
   model-authored *prose* would not destabilise the digest at all. The
   dangerous field is `target` — which is precisely what the ticket's
   option (c) proposes to start populating. Attribution must be
   deterministic *even if prose were not*. See [§5](#5-why-not-a).

6. **(d) is declined as specified, and replaced.** Suppressing the
   payload-less kinds would discard the only fleet-level record that four
   distinct tasks were rejected for missing test coverage — reintroducing
   exactly the "counts from zero three weeks later" defect Stage 2 exists to
   fix (`pending_write.ex:6-11`). The legitimate complaint underneath (d) is
   *legibility*, not generation, and it gets a cheaper fix: label rows that
   cannot apply as written, so an operator learns it from the listing instead
   of from pressing apply. Filed as `bd-bldypb` (#1475).

7. **The honest limit of determinism, stated plainly:** the analyser can
   render the evidence, the citation, the target and the framing. It cannot
   derive the *imperative sentence* — "confirm every new branch has a test
   that fails without the change". That sentence is authored once per
   category, by a human, in code, next to the regex that produces the
   category. Five categories, five sentences, one file. That is the entire
   thing an LLM pass would buy, and it is not worth a nondeterministic
   analyser.

---

## What I measured

Live install, 2026-09-04, via `arb loop pending --json` and `arb workspace
list --json`.

### The queue

| state | `difficulty_override` | `config_set` | `skill_patch` | `repo_doc_patch` |
|---|---|---|---|---|
| `:proposed` | 14 | 3 | 3 | 0 |
| `:hypothesis` | 0 | 3 | 1 | 0 |
| `:applied` | 8 | 0 | 0 | 0 |
| `:rejected` / `:superseded` | 0 | 0 | 0 | 0 |

**6 of the 20 currently-`:proposed` rows (30%) cannot be applied by
construction.** The ticket's "4 live hypotheses, 8 applied" has moved on; the
shape of the finding has not, and the payload-less share has grown.

Zero `repo_doc_patch` rows have ever existed, in any state.

### The failures are real, and they are clean

Both applies below were run against live `:proposed` rows. Neither changed
state — `Apply.run/2` orders `side_effect` before `persist` (`apply.ex`),
so a payload gap aborts before anything is written. Re-checked after: both
still `:proposed`.

```
$ arb loop apply 019fed75-0d73-75b2-970a-4c797a5a3251     # skill_patch
arb: error: this proposal names no target skill: the loop does not yet map a
finding category to a skill (Stage 3 work), so the skill patch must be
authored by hand — reject this row once you have
      details: {"code":"unmapped"}

$ arb loop apply 01a059a3-afc3-7e15-b2a2-aa754655bb73     # config_set
arb: error: payload is missing a non-empty "patch" map
      details: {"code":"unmapped"}
```

`arb loop diff` on the same skill_patch row ends with
`(no diff — this proposal carries a payload, not a patch)`. The queue is
honest about the gap at every surface except the listing, which is the one an
operator reads first. Hence `bd-bldypb`.

### The `Loop` determinism guarantee still holds

Re-verified today, and the module list has grown since the ticket was
written without breaking it. Outbound `Arbiter.*` references from
`lib/arbiter/loop.ex` + `lib/arbiter/loop/`:

```
Agents.Routing, Agents.Routing.ByDifficulty, Boot.Migrator, Events, Mergers,
Messages.Message, PubSub, Quota, Release, Repo, Skills, Tasks, Tasks.Issue,
Tasks.Workspace, Usage, Usage.Event, Usage.WorkspaceBackfill,
Worker.OutputLog, Worker.StopReason, Worker.Worktree
```

No `Req` / `Finch` / `Tesla` / `:httpc` / `HTTPoison` anywhere under
`lib/arbiter/loop`. Every addition since the ticket's verification
(`Routing`, `Events`, `PubSub`, `Worktree`, `Mergers`) is local and
deterministic.

### The finding-category set is closed, and small

`@finding_buckets` (`analysis.ex`) is four compile-time regexes:

| category | live row | an existing skill governs it? |
|---|---|---|
| `plausible code, green tests, inert at runtime` | `:proposed` | **yes** — `verification-before-completion` |
| `missing test coverage` | `:proposed` | **yes** — `test-driven-development` |
| `regression in existing behaviour` | `:proposed` | **yes** — `test-driven-development` |
| `secret / credential exposure` | `:hypothesis` | **no** |
| `context exhaustion` (from `from_context`, not a bucket) | none live | **no** |

The fleet has exactly three skills, all global:
`systematic-debugging`, `test-driven-development`,
`verification-before-completion`. `Skill.managed_by` exists
(the `managed_by` attribute in `skill.ex`, #1465, closed) — the stated
prerequisite is satisfied.

**This is the measurement that decides the ticket.** "Category → skill
attribution" reads like an open relation to be discovered. It is a five-row
table over a closed set, three of whose rows are unambiguous and two of whose
rows resolve to *"no skill governs this — the correct kind is `:skill_create`,
not `:skill_patch`"*.

### The routing tiers all resolve to real changes

`ByDifficulty.default_mapping/0` (`by_difficulty.ex`), with every
workspace's own `routing.rules` merged on top:

| workspace | policy | own rules |
|---|---|---|
| `default` (repo `arbiter`) | `by_difficulty` | `D4 => flagship/xhigh` |
| `vstim` (repo `vstim`) | `by_difficulty` | `D4 => flagship/xhigh` |
| `emricare` (repos `tonic`, `tonic_device`) | `by_difficulty` | `D4 => flagship/xhigh` |

Resolving each live cluster's `D<from> → D<to>` step:

| live cluster row | patch it would carry | identity? |
|---|---|---|
| D3/vstim → D4 | `routing.rules.D3 = flagship/xhigh` | no (vstim overrides D4) |
| D2/vstim → D3 | `routing.rules.D2 = premium/high` | no |
| D2/arbiter → D3 | `routing.rules.D2 = premium/high` | no |
| D1/vstim → D2 | `routing.rules.D1 = standard/medium` | no |
| D1/arbiter → D2 | `routing.rules.D1 = standard/medium` | no |
| D0/arbiter → D1 | `routing.rules.D0 = economy/low` | no |

6/6 real. Note D3→D4 is only non-identity *because* every workspace happens to
override D4 today; against stock `default_mapping/0` both tiers are
`premium/high`. The implementation must resolve against the workspace's
effective rule and **decline to emit an identity patch**, or it recreates the
permanently-stuck-row failure that `proposable_misestimate?/1` already guards
against at the difficulty ceiling (`proposals.ex`).

---

## 1. Three problems, not one

The ticket's framing — "three of the five kinds are generated with no payload
content" — is accurate for two of them and wrong for the third.

`repo_doc_patch` **is not generated at all.** `Proposals.finding_kind/1`'s
`:claude_md` clause (`proposals.ex`) is reachable only when a suggestion's
`destination` is `:claude_md`, and `Analysis.suggestion_targets/2` — the sole
producer of `destination` (`analysis.ex`) — returns `:per_task_override` or
`:skill` and never `:claude_md`. The branch, and `finding_gist(:claude_md, _)`
beside it, are unreachable from the analyser. Zero rows in the queue's entire
history confirm it.

The one live `:repo_doc_patch` path is the operator-invoked
`arb loop propose repo-doc-patch --repo … --lesson …`
(`Loop.propose_repo_doc_patch/1`, `loop.ex`), which supplies both repo and
prose by hand. It is not payload-less; it is not automatic; it is working as
designed.

So there is nothing here to author and nothing to suppress. What there is, is
dead code making a false promise in a `@moduledoc` (`proposals.ex:14-16`
still describes the `:claude_md` → `:repo_doc_patch` route as live). Filed
separately as `bd-ipq68i` (#1476) — either produce the destination or delete
the branch; do not leave a documented route with no producer.

---

## 2. `config_set` — option (b), and it is small

### What exists

`Proposals.misestimate_cluster_candidates/3` (`proposals.ex`) already groups
misestimates by `{from_difficulty, to_difficulty, repo}` and writes:

```elixir
payload: %{
  "cell" => %{"from_difficulty" => from, "to_difficulty" => to, "repo" => repo},
  "task_ids" => task_ids,
  "reason" => "rework_cluster"
}
```

`Apply.side_effect/2`'s `:config_set` clause (`apply.ex`) wants
`payload["patch"]` and hands it to the deep-merge `:patch_config` action.

### What is missing

One function. Given the cell and the workspace:

```
patch = %{"routing" => %{"rules" => %{"D#{from}" => effective_rule(workspace, to)}}}
```

where `effective_rule(ws, d)` is `default_mapping()[d]` merged under
`get_in(ws.config, ["routing", "rules", "D#{d}"])` — i.e. *"route the
under-provisioned tier the way this workspace already routes the tier above
it"*. That is the exact semantic content of the gist the row already prints:
*"raise default dispatch difficulty for D2/arbiter to D3"*.

Every input is a value already in hand. No prose. No model. No ambiguity.

### The three things that make it non-trivial anyway

1. **Identity patches must be declined**, per the measurement above — with the
   candidate dropped, not emitted-and-failed.
2. **`repo` is in the fingerprint but not in the patch.** `routing.rules` is
   per-difficulty and workspace-wide; there is no per-repo routing key. A
   D2/`arbiter` cluster patching `routing.rules.D2` therefore also moves D2
   dispatches for every other repo in that workspace. Today that is a
   non-issue (`default` has exactly one repo), and `emricare` — the one
   two-repo workspace — has no live clusters. It will stop being a non-issue.
   The row's gist must say what it actually changes, and the follow-up issue
   must decide between (i) keeping `repo` as a fingerprint input while the
   patch is workspace-wide and saying so, or (ii) collapsing the cluster cell
   to `{from, to}` per workspace. **(i)** is the recommendation: dropping
   `repo` from the cell would re-fingerprint and orphan all six live rows for
   a problem no workspace has yet.
3. **This makes rows canary-eligible, which is a real autonomy change.**
   A `:config_set` carrying a well-formed one-tier `routing.rules` patch is,
   by `Canary.eligible/1`, a candidate for *autonomous* application on a
   workspace that has set `loop.autonomous_routing_enabled` — no workspace has
   (all three have `loop: null`), and Invariant 2's "no auto-apply" is scoped
   by that flag, not by this change. But the follow-up must land with that
   consequence stated in the PR body, not discovered afterwards.

---

## 3. `skill_patch` — (c) is necessary and **not sufficient**

### The trap in option (c)

The ticket offers (c) as "carry a named target plus evidence with no prose — a
human writes the diff". Applied literally, that row **still fails**:
`Payload.skill_attrs/1` (`apply/payload.ex`) requires at least one of
`body` / `metadata` / `activation_mode` and returns
`{:unmapped, "this proposal carries no skill patch content to apply"}`
otherwise. Naming the target only moves the failure from the first `with`
clause to the second.

So (c) alone does not satisfy #1141's criterion — the destination would
resolve, but the row would still be *"advice a human must hand-apply"*, just
with better addressing. `skill_patch` needs (c) **and** (b): a deterministic
target *and* deterministically-rendered content.

### Attribution: a compile-time table, next to the regexes

The map belongs in `analysis.ex` beside `@finding_buckets`, because it is the
same closed set and the two must not drift:

| category | kind | target |
|---|---|---|
| `plausible code, green tests, inert at runtime` | `:skill_patch` | `verification-before-completion` |
| `missing test coverage` | `:skill_patch` | `test-driven-development` |
| `regression in existing behaviour` | `:skill_patch` | `test-driven-development` |
| `secret / credential exposure` | `:skill_create` | *(new skill)* |
| `context exhaustion` | `:skill_create` | *(new skill)* |

Two consequences worth stating explicitly:

* **Routing unhomed categories to `:skill_create` is the right answer, not a
  fallback.** That kind has full payload support already
  (`Apply.side_effect/2`'s `:skill_create` clause, `apply.ex`),
  forces `managed_by: :loop`, and is the honest description of what the fleet
  needs: there is no security-practice skill and no context-budget skill, and
  a `skill_patch` against a skill that does not exist would fail with
  `{:unmapped, "no skill named …"}` forever.
* **Skills are global today; the table is not workspace-aware.** All three
  skills have `workspace_id: nil`. A per-workspace skill of the same name
  would make the target ambiguous. Out of scope now; named so the follow-up
  does not silently assume global forever.

### Content: what a template can and cannot render

The candidate already carries `category`, one verbatim `example` finding
string, `incident_refs`, `task_refs`, and the pre-registered
`target_metric` / `baseline` (`Proposals.finding_candidates/3`,
`proposals.ex`). A rendered clause can therefore be fully derived except for
one sentence:

```markdown
## Missing test coverage                      <- derived (category)
                                                 
Reviewers rejected 4 tasks this window for    <- derived (incidents, tasks)
missing test coverage, e.g. bd-3kgb0e:        <- derived (task_refs)
"<verbatim reviewer finding>".                <- derived (example)

Before requesting review, confirm every new   <- NOT derivable: authored
branch has a test that fails without the         once, per category, in code
change.

<!-- loop:proposal:019fed75-… · 4 incidents / 4 tasks · 2026-09-04 -->
                                              <- derived (provenance)
```

**Can** be produced deterministically: the heading, the evidence sentence, the
verbatim citation with its task id, the provenance comment, the
`managed_by: :loop` attribution, and an `arbiter:begin`/`arbiter:end`-style
marker pair so a later window replaces its own clause instead of appending a
fifth copy.

**Cannot** be produced deterministically: the imperative. There is no
mechanical route from *"reviewers said 'no test for the error branch'"* to
*"write the failing test first"*. That sentence is a per-category constant —
five of them, in the same file as the five regexes that produce the
categories.

This is the same structural move #1464 made for discovery: push the one
irreducibly-linguistic step out of the runtime and into source code a human
merges. There, a model drafts it and a human merges; here, a human writes five
sentences once and no model is involved at all. At five categories, the model
is not carrying its weight.

### The migration that must not be missed

`target` **is** a fingerprint input (`Loop.fingerprint/1`, `loop.ex`).
Populating it changes the digest of every finding-category row. The four live
`skill_patch` rows
carry `target: nil` and 4–5 incidents of accumulated evidence each; a naive
deploy inserts four *new* rows beside them and leaves the old ones live,
holding the evidence, forever un-reinforced — the partial unique index is on
`(fingerprint, state)`, so nothing stops both existing.

The follow-up must therefore ship a backfill: recompute each live
finding-category row's fingerprint under the new `target`, or mark the old row
`:superseded` and carry its `incident_refs` / `task_refs` onto the new one.
`:superseded` exists for exactly this (`pending_write.ex:26`).

Generalising: **the category→target table is fingerprint-load-bearing.**
Editing it is a schema-shaped change requiring a supersede/backfill step, not
a copy edit. That is a standing cost of (c) the ticket does not mention — and
an independent argument against any scheme where a model picks targets, since
a model that re-decides weekly produces a supersede storm and an evidence
count that never accumulates.

### As shipped (bd-5w8h0r, #1474)

The table lives in `Arbiter.Loop.FindingBuckets`, beside the regexes that
produce the categories it keys on, with a **compile-time totality guard in
both directions**: a bucket with no attribution row, or an attribution row
matching no bucket, raises `CompileError`. The imperative sentence is the
third column of each row, so a new bucket cannot ship without one.

Two things went differently from the sketch above, both deliberate:

* **The clause is spliced at apply time, not at pass time.** A `:skill_patch`
  payload carries `"clause"` + `"clause_id"` and no `"body"`;
  `Arbiter.Loop.Apply.Payload.skill_attrs/2` resolves it against the skill's
  *current* body via `Arbiter.Loop.SkillClause.upsert/3`. Rendering a whole
  body at pass time and applying it weeks later would silently revert any
  human edit made in between — the failure `RepoDocPatch` exists to prevent on
  a repo `CLAUDE.md`. `:skill_create` payloads do carry a full `"body"`, since
  there is no existing body to clobber.
* **The provenance comment cites the fingerprint, not the row id.** The
  pending-write id does not exist when the payload is authored — the row is
  inserted *from* the payload. `loop:proposal:<id>` still lands on the skill's
  paper-trail version via `Arbiter.Loop.Apply.attribution/1`, so both
  identifiers are recoverable.

The backfill is `Arbiter.Loop.PendingWriteTargetBackfill`, run from
`priv/repo/migrations/*_backfill_loop_pending_write_targets.exs`. It is plain
SQL for the same reason `PendingWriteWorkspaceBackfill` is: under
`bin/arbiter eval Arbiter.Release.migrate` the repo is started and Ash is not.
It leaves `:rejected` rows alone (a rejection is a record of a decision about
a proposal the successor is not) and leaves a category with no attribution row
live, counted `unresolved`, rather than guessing a target.

One standing consequence the table's moduledoc now carries: once the loop has
created one of the two `:skill_create` skills, a later window's row for that
category is still `:skill_create` and will fail on the unique-name constraint.
Moving it to `:skill_patch` is itself a fingerprint change and takes the same
supersede/backfill step. Deciding the kind at apply time from whether the
skill happens to exist would have made the fingerprint depend on mutable state
outside the table — the exact property this section argues against.

---

## 4. `repo_doc_patch` — nothing to decide here

Covered in [§1](#1-three-problems-not-one). Split to `bd-ipq68i` (#1476) as a
dead-code / stale-doc cleanup, not as payload authoring.

---

## 5. Why not (a)

Recorded even though the line is not crossed, because the analysis inverts the
ticket's own statement of the risk and that inversion is the durable finding.

### Nondeterminism vs. fingerprint stability

The ticket says an LLM pass "interacts badly with the fingerprint-reinforcement
mechanic that assumes a stable digest". Measured against `Loop.fingerprint/1`
and its `@doc` (`loop.ex`):

* The digest is `{kind, target, category, difficulty, repo}`. `payload`,
  `gist`, `diff`, `baseline` and `incident_refs` are **deliberately excluded**
  — "those are what accumulate, so including them would make every window a
  fresh fingerprint and defeat the mechanic".
* Therefore **model-authored prose is fingerprint-neutral.** A different clause
  every week reinforces the same row. The mechanic is unbothered.
* The exposure is `target`, and `category`. A model choosing the target means
  the same finding fingerprints to `test-driven-development` this week and
  `verification-before-completion` next: two live rows, one finding, evidence
  split across both, neither clearing the bar. That defeats reinforcement
  completely and silently.

So the risk is not where the ticket puts it. **Prose is the safe part. The
target is the dangerous part** — and option (c), "solve attribution only", is
the option that most requires determinism, not the one that least does.

This is also why (a) is not merely unnecessary but structurally awkward: the
part of the payload an LLM is genuinely good at (prose) is the part with the
smallest surface area — five sentences — while the part that must stay
deterministic (attribution) is the part the ticket frames as the hard problem.

### Cost accounting, had it been chosen

For the record, the accounting an (a) implementation would have owed:

* Recorded through `Corpus.record_pass_cost/1` (`corpus.ex`), which already
  inserts one `usage_events` row per pass under `task_id: "loop-analyze"`,
  `step: :other`, `provider: "arbiter"` — the loop's cost lands in the ledger
  it optimises. An authoring pass needs a distinct `model` label so its draw is
  separable from the deterministic pass's duration-only row.
* Reported in **quota-window units, not only dollars** — per `bd-69gk52`
  (#1463), the binding constraint is the 5-hour window, not imputed spend. An
  authoring pass runs once per finding category per analysis window; at five
  categories and a weekly cadence its draw is small, but "small" must be
  measured in the unit that binds.
* Shared with `bd-4f6opo` (#1468) rather than duplicated: #1464 §8 already
  commits that if both crossed the line they would share one opt-in flag
  surface and one cost path. That obligation now lapses on this side —
  authoring adds no flag and no cost.

The default path stays free, so `bd-69gk52`'s note that *"the analyser's own
quota draw is negligible while `Loop` stays deterministic"* remains true
without qualification.

---

## 6. (d) — decided explicitly: declined as written, replaced

**Do not suppress generation of the payload-less kinds.**

The reasoning:

* **Suppression discards evidence, which is the one thing Stage 2 exists to
  keep.** `pending_write.ex:6-11` names the defect precisely: a below-bar
  finding, discarded, means "its third occurrence three weeks later started
  counting from zero". The four live `skill_patch` rows are the only
  fleet-level record that missing test coverage has been raised against four
  distinct tasks. Suppressing them to tidy the listing trades the epic's core
  mechanic for cosmetics.
* **It would also suppress the six `config_set` rows** — the ones whose fix is
  a table lookup, and which additionally gate the shipped-but-unreachable
  canary. Interim suppression would be undone by the very next PR.
* **The rows are not misleading.** Both apply paths fail with an accurate,
  specific message that names the gap as a gap, and `arb loop diff` says
  `(no diff — this proposal carries a payload, not a patch)`. Nothing here is
  a trap; it is an unlabelled listing.

**What the complaint actually earns.** *"A queue containing permanently-
inapplicable items is a queue operators stop reading"* is right about the
symptom and wrong about the cause: the cost is not that the rows exist, it is
that an operator cannot tell which rows are actionable without pressing apply
on each. So label them. `arb loop pending` and `loop_pending_list` should
compute whether a row's payload would satisfy its kind's `Apply` preconditions
and mark it — `needs authoring` beside the state — without running any side
effect. Cheap, evidence-preserving, and useful permanently rather than as an
interim. Filed as `bd-bldypb` (#1475), and it can land before either
authoring slice.

---

## 7. What the deterministic path can and cannot produce

Required by the acceptance criteria, collected in one place.

**Can:**

* A complete, applicable `:config_set` routing patch — every input is already
  structured. No expressive loss whatsoever; the deterministic patch *is* the
  gist the row already prints.
* A correct target for every finding category the analyser can emit, including
  the correct decision to route two of the five to `:skill_create` instead.
* A skill clause carrying: the category heading, the incident and distinct-task
  counts, a verbatim reviewer-finding citation with its task id, a proposal-id
  provenance marker, and a replace-in-place marker pair.
* `managed_by: :loop` attribution and a normal PaperTrail version under
  `loop:proposal:<id>`, unchanged from today.

**Cannot:**

* Write the guidance sentence. One per category, authored by a human in source.
  Five today; a sixth category means a sixth sentence in the same commit as its
  regex, which is a feature — an unhomed category cannot silently ship an empty
  clause.
* Synthesise a *new* skill's body from scratch. The two `:skill_create`
  categories need a first draft a human writes; after that they are ordinary
  `:skill_patch` targets. Recommendation: the loop proposes `:skill_create`
  with a stub body and the evidence, and an operator fills it — the destination
  is real, which is what #1141 asks for.
* Attribute a finding to a *repo*. `finding_categories/1` aggregates fleet-wide
  with no repo cell (`Analysis.finding_categories/1`, `analysis.ex`), which is
  why `:claude_md` has no producer. Nothing here changes that; see
  `bd-ipq68i`.
* Generalise across categories. Every clause is per-category by construction.
  A finding that spans two categories yields two clauses, not one synthesis.

The gap between "can" and "cannot" is five English sentences and one stub skill
body. That is the entire price of keeping `Loop` deterministic, and it is
cheaper than the accounting, flagging and supersede-storm machinery that
option (a) would have to carry.

---

## Rejected alternatives

| alternative | why rejected |
|---|---|
| **(a) LLM authoring pass** | Its only unique contribution is one sentence per category over a closed five-element set. Buys nondeterminism, a quota draw in the ledger the loop optimises, and an opt-in flag surface, for five sentences a human writes once. |
| **(a) restricted to prose, with deterministic targets** | The strongest version of (a), and still declined — but note it is *safe* on the fingerprint (payload is not a digest input). It is a live option if the category set ever stops being closed; `bd-5ja2vb`/`bd-4f6opo` (#1467/#1468) is the thing that would open it. Revisit then, not now. |
| **(c) alone — named target, no content** | Does not apply. `Payload.skill_attrs/1` requires content; the row would fail one `with` clause later with a different message. Fails #1141's "real, actionable path" criterion for the same reason it does today. |
| **(d) as written — suppress the three kinds** | Discards accumulated evidence (the exact defect Stage 2 fixes), suppresses six rows whose fix is a table lookup, and would be reverted by the next PR. Replaced by labelling. |
| **Model bins findings into a controlled vocabulary at authoring time** | Puts a model judgment inside `category`, a fingerprint input. Same objection #1464 raised, and worse here: it destabilises rows that already hold evidence. |
| **Emit `:skill_patch` against a skill that does not exist, and create it on apply** | Hides a create behind a patch. `:skill_create` exists, has full payload support, and forces `managed_by: :loop`. |
| **Collapse the cluster cell to `{from, to}` so the patch matches its scope** | Correct in the abstract; re-fingerprints and orphans all six live `config_set` rows to fix a problem no current workspace has. Revisit when a multi-repo workspace produces a cluster. |
| **Ship `config_set` authoring without an identity-patch guard** | Recreates the permanently-stuck-row failure `proposable_misestimate?/1` already guards at the difficulty ceiling — a row that fails validation on every `apply all`, forever. |

---

## Implementation issues

Filed by this ticket. All four carry a `depends_on` edge to `bd-blxwla`
(#1465, `Skill.managed_by`), which is **closed** — the prerequisite the ticket
names is satisfied, and the edges are recorded so the ordering is legible
rather than incidental.

1. **`bd-53cuj6` (#1473) — `config_set`: author the routing-tier patch
   deterministically.**
   Render `routing.rules.D<from> => effective_rule(workspace, to)` in
   `misestimate_cluster_candidates/3`; resolve against the workspace's own
   rules merged over `ByDifficulty.default_mapping/0`; decline identity
   patches instead of emitting them; keep `repo` in the fingerprint and say in
   the gist that the patch is workspace-wide. Acceptance: all six live rows
   apply, and `Canary.parse_routing_patch/1` accepts the emitted shape — the
   canary gets its first production producer. The PR body must state the
   autonomy consequence (rows become canary-eligible on a workspace that has
   set `loop.autonomous_routing_enabled`; none has).

2. **`bd-5w8h0r` (#1474) — `skill_patch`: deterministic category→target
   attribution and a rendered clause.**
   Compile-time table beside `@finding_buckets`; unhomed categories route to
   `:skill_create` with a stub body; per-category imperative sentence as a
   module constant; marker-delimited clause so a later window replaces rather
   than appends. **Ships with the fingerprint backfill** — the four live
   `target: nil` rows are superseded onto their new-fingerprint successors
   carrying their `incident_refs` / `task_refs`, not left live beside them.
   `depends_on bd-53cuj6`: both edit `Proposals`, and the smaller, canary-
   unblocking slice should land first — this one additionally carries a data
   migration.

3. **`bd-bldypb` (#1475) — mark rows that cannot apply as written.**
   The replacement for (d). `arb loop pending` and `loop_pending_list` compute
   each row's applicability from its payload against its kind's `Apply`
   preconditions — no side effect, no state change — and surface it in the
   listing. Independent; can land first, and stays useful after 1 and 2.

4. **`bd-ipq68i` (#1476) — the `:claude_md` destination has no producer.**
   `finding_kind(:claude_md)` / `finding_gist(:claude_md, _)` are unreachable:
   `suggestion_targets/2` never returns `:claude_md`, and zero
   `:repo_doc_patch` rows have ever been generated. Either give the destination
   a producer (needs per-repo finding aggregation, which
   `finding_categories/1` does not do) or delete the branch and correct
   `Proposals`' `@moduledoc`, which still documents the route as live. Lowest
   priority of the four.
