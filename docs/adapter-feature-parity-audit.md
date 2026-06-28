# Adapter feature-parity audit

> Audit directive: **bd-c1hlgj** — _audit: feature parity across all tracker,
> merger, and forge adapters — file gaps as directives_.
> Date: 2026-06-28. Scope: read every tracker / merger / forge adapter, compare
> against the behaviour contracts, file one directive per concrete gap. **No
> behaviour is changed by this directive** — the deliverable is this document
> plus the child directives it links.

## What was audited

| Layer | Behaviour contract | Adapters in tree |
|-------|--------------------|------------------|
| Tracker | `Arbiter.Trackers.Tracker` (`lib/arbiter/trackers/tracker.ex`) | GitHub, Jira, Shortcut, None — **Linear missing** |
| Merger / forge | `Arbiter.Mergers.Merger` (`lib/arbiter/mergers/merger.ex`) | GitHub, GitLab, Direct |

Dispatchers: `Arbiter.Trackers` (`trackers.ex`) resolves by `issue.tracker_type`;
`Arbiter.Mergers` (`mergers.ex`) resolves by `workspace.config["merge"]["strategy"]`.
Optional callbacks are guarded at call sites with `function_exported?/3`, so a
missing optional callback degrades silently rather than crashing — which is
exactly why these gaps were invisible until now.

Method: the callback set of each behaviour was cross-referenced against the
`def`/`@impl` definitions in every adapter module, and each gap was traced to
its consuming call site to confirm real functional impact (not just a missing
stub).

## Tracker feature matrix

Legend: **Y** = implemented · **—** = not implemented · **N/A** = no-op by
design (the backend has no such concept).

| Callback | Required? | GitHub | Jira | Shortcut | None |
|----------|:---------:|:------:|:----:|:--------:|:----:|
| `fetch/1` | yes | Y | Y | Y | Y |
| `transition/2` | yes | Y | Y | Y | Y |
| `update_fields/2` | yes | Y | Y | Y | Y |
| `link_for/1` | yes | Y | Y | Y | Y |
| `parse_ref/1` | yes | Y | Y | Y | Y |
| `list_transitions/1` | yes | Y | Y | Y | Y |
| `list_open/1` | yes | Y | Y | Y | N/A¹ |
| `create/1` | yes | Y | Y | Y | N/A¹ |
| `current_user/0` | yes | Y | Y | Y | N/A¹ |
| `assignees/1` | yes | Y | Y | Y | Y |
| `issue_status/1` | yes | Y | Y | Y | Y |
| `extract_title/1` | yes | Y | Y | Y | Y |
| `extract_description/1` | yes | Y | Y | Y | Y |
| `add_remote_link/3` | optional | Y | Y | Y | N/A |
| `add_comment/2` | optional | **—** G2 | Y | **—** G3 | N/A |
| `gating_fields/2` | optional | — A1 | Y | — A1 | N/A |
| `check_prior_claim/1` | optional | Y | Y | Y | N/A |
| `signal_claim/3` | optional | Y | Y | Y | N/A |
| `search_by_title/1` ² | undeclared | Y | **—** G4 | **—** G5 | N/A |

¹ `None` returns `{:error, :not_supported}` (or the empty/identity value) by
design — there is no upstream backlog, no remote user, nothing to create.
² `search_by_title/1` is **not declared** in the `Tracker` behaviour at all; it
is an informal optional callback dispatched via `function_exported?/3`
(`trackers.ex:273`). See **A3 / G9**.

**Linear** has no row because no `Arbiter.Trackers.Linear` module exists, even
though `:linear` is a first-class `tracker_type` in the enum, the moduledoc, and
`trackers.ex:12`. See **G1 / A4**.

## Merger / forge feature matrix

| Callback | Required? | GitHub | GitLab | Direct |
|----------|:---------:|:------:|:------:|:------:|
| `open/4` | yes | Y | Y | Y |
| `get/1` | yes | Y | Y | Y |
| `merge/1` | yes | Y | Y | Y |
| `close/1` | yes | Y | Y | Y |
| `add_comment/2` | yes | Y | Y | N/A³ |
| `request_review/2` | yes | Y | Y | N/A³ |
| `link_for/1` | yes | Y | Y | N/A³ |
| `get_diff/2` | yes | Y | Y | Y⁴ |
| `post_inline_comment/3` | yes | Y | Y | Y⁴ |
| `submit_review/4` | yes | Y | Y | Y⁴ |
| `list_review_feedback/1` | yes | Y | Y | N/A³ |
| `update_branch/1` | optional | Y | **—** G6 | N/A⁵ A2 |
| `failing_check_logs/1` | optional | Y | **—** G7 | N/A⁵ |
| `list_open/0` | optional | Y | **—** G8 | N/A³ |
| `list_open_review_threads/1` | optional | Y | Y | N/A³ |
| `ref_for_pr/2` | optional | Y | Y | N/A³ |

³ `Direct` is the local-merge strategy: no MR, no review surface, no web UI —
these callbacks are intentionally no-ops / `{:ok, neutral}`.
⁴ `Direct` implements the review trio locally: `get_diff` = `git diff base..branch`,
`post_inline_comment`/`submit_review` write the verdict to the local checkout.
⁵ `Direct` has no CI and (currently) no branch-update step. The `update_branch`
contract text is self-contradictory about whether `Direct` *should* support a
local rebase-forward — see **A2**.

## Gaps — each has a filed directive

All directives below are children of **bd-c1hlgj** (`Progress: 0/9 children`).

| # | Gap | Impact | Directive |
|---|-----|--------|-----------|
| G1 | **Linear tracker adapter missing entirely.** `:linear` resolves to `None` via the unknown-type fallback (`adapter_for_workspace_type/1`). | A Linear-configured workspace silently behaves as untracked: no fetch, no sync, no claim, no create-mirror. | **bd-3ri70e** |
| G2 | GitHub tracker lacks `add_comment/2`. | On PR-open, the "Arbiter opened a pull request" comment (`sync.ex:228`) is dropped for GitHub tickets (the remote link still attaches). | **bd-dmfwfn** |
| G3 | Shortcut tracker lacks `add_comment/2`. | Same PR-open comment dropped for Shortcut stories. | **bd-caz8dr** |
| G4 | Jira tracker lacks `search_by_title/1`. | Upstream-create dedup (`search_by_title_for_workspace/2`) only works for GitHub; Jira can mint duplicate tickets. | **bd-5ombd9** |
| G5 | Shortcut tracker lacks `search_by_title/1`. | Same dedup gap for Shortcut. | **bd-6h2y8y** |
| G6 | GitLab merger lacks `update_branch/1`. | MergeQueue/watchdog skip the continuous rebase-forward (`merge_queue.ex:788`, `watchdog.ex:700`); GitLab MRs go stale against a moving base. | **bd-cxm8zr** |
| G7 | GitLab merger lacks `failing_check_logs/1`. | Watchdog ci-failed fix passes (`watchdog.ex:1147`) get no failure briefing on GitLab. | **bd-6iimwq** |
| G8 | GitLab merger lacks `list_open/0`. | PRPatrol + supervisor (`pr_patrol.ex:140`, `pr_patrol_supervisor.ex:49`) skip GitLab workspaces entirely — no patrol of open GitLab MRs. | **bd-7k6x5i** |
| G9 | `search_by_title/1` is undeclared in the `Tracker` behaviour. | Adapter authors have no contract signalling the callback exists; it is only discoverable by reading the dispatcher. | **bd-9po2c7** |

## Ambiguities — flagged for Admiral review (no directive filed)

These have **no clear answer** and are deliberately left unfiled until the
Admiral rules on intent.

- **A1 — Is provider-side field gating a Jira-only concept?** `gating_fields/2`
  is implemented only by Jira (it models the VR board's required QA / deployment
  fields). GitHub and Shortcut have no equivalent required-field-before-transition
  mechanism, so leaving it unimplemented is *probably* correct — but if we ever
  want GitHub/Shortcut to enforce "fill notes before close", an equivalent would
  be needed. Decision: confirm Jira-only is intended, or open a directive to
  model gating elsewhere.

- **A2 — Should `Direct` implement `update_branch/1`?** The contract text is
  self-contradictory: the `@doc` describes how a *local* adapter would do it
  ("a rebase/merge of the base onto the branch + push") yet the same doc lists
  `Direct` among adapters that "can't update a branch". With the base-aware merge
  queue (Crucible), a `Direct` workspace currently never rebases-forward. Decision:
  either implement a local rebase-forward for `Direct`, or amend the contract to
  drop the "local adapter" language and declare `Direct` genuinely out of scope.

- **A3 — Should dedup-on-create (`search_by_title/1`) be a first-class contract
  behaviour?** It is currently an undeclared informal callback. G9 declares it as
  an optional callback; the open question is whether dedup-on-create should be a
  *recommended* capability every tracker adapter implements, or remain best-effort.

- **A4 — Silent `None` fallback for known-but-unshipped tracker types.** A
  workspace whose `tracker_type` is `:linear` (a value the enum knows) resolves to
  `None` with no warning — indistinguishable from an intentionally-untracked
  workspace. Decision: should the resolver log/raise loudly for a *known* type
  that has no shipped adapter (vs. a genuinely-unknown type), so misconfiguration
  is visible? (Related to G1 but a distinct policy question that outlives it.)

- **A5 — PR-open comment vs. remote-link parity.** Jira tickets get *both* an
  "Arbiter opened a PR" comment *and* a remote link on PR-open; GitHub/Shortcut
  currently get only the remote link (the comment is dropped as `:not_supported`).
  G2/G3 would close the gap by adding `add_comment`, but the Admiral should confirm
  the *desired* end state: is a comment wanted **in addition to** the remote link
  for forge-style trackers, or is the remote link sufficient there (making G2/G3
  lower priority)?

## Summary

- **2 behaviour contracts**, **7 adapters** audited (4 tracker + 3 merger), plus
  the shared claim / remote-link / CI surfaces.
- **9 gap directives filed** (G1–G9), all children of bd-c1hlgj.
- **5 ambiguities** (A1–A5) surfaced for Admiral decision — none auto-filed.
- Headline gaps: **Linear is entirely unimplemented** (G1), and **GitLab is
  missing the three optional forge callbacks** that drive rebase-forward, CI-fail
  briefing, and PR patrol (G6–G8) — so GitLab workspaces silently lose those
  automations today.
