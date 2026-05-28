# Review: feature/bd-6c6w82-implement-github-merger-adapter

**Bead:** bd-6c6w82 (reviewed under bd-d66lwi)
**Builder:** polecat (PR #12, commit 1f74837)
**Reviewer:** polecat (bd-d66lwi)
**Date:** 2026-05-28 22:30

## Diff summary

Adds `Arbiter.Mergers.Github`, the second `Merger` adapter (after `Direct`),
wrapping GitHub's REST v3 PR API for open / get / merge / close / comment /
request-review. It mirrors the `Arbiter.Trackers.Jira` shape exactly: a
workspace-scoped `Config` resolver (process dict → `Application` env → error),
a normalised `Error` struct, and a thin `Github` module whose `mr_ref` is the
opaque `"#<number>"` string with owner/repo/token resolved from config rather
than carried in the ref. The dispatcher (`Arbiter.Mergers`) gains
`github: Github`; `Workspace.@valid_merger_strategies` becomes `~w(direct
github)` and `ValidateConfig`'s moduledoc is updated accordingly. HTTP is
routed through `Req` with a `Req.Test` plug injected when
`:github_http_stub` is set. Tests cover all seven callbacks plus config and
dispatcher wiring (43 tests across the two touched suites). The PR also
incidentally re-formats `workspace.ex`'s Ash DSL back to the canonical
paren-free `Spark.Formatter` style (the stacked base branch had drifted).

## Acceptance criteria check

- [x] **Approved logic correct (APPROVED exists, no CHANGES_REQUESTED)** —
  `approved?/1` (github.ex:236) computes
  `"APPROVED" in states and "CHANGES_REQUESTED" not in states` over the review
  list, falling back to `false` for a non-list. Matches the bead contract to
  the letter. Directly tested: one-approval → `approved: true`; an
  `APPROVED` + `CHANGES_REQUESTED` mix → `approved: false`; empty reviews →
  `approved: false`.
- [x] **merge_method config respected** — `merge/1` (github.ex:113) sends
  `%{"merge_method" => Atom.to_string(cfg.merge_method)}`; `Config.merge_method/1`
  maps `"squash"|"merge"|"rebase"` to the atom and defaults to `:squash` on
  anything else. Tested with the default `squash` body and a `rebase` override.
- [x] **owner+repo config resolved cleanly** — `Config.resolve/0` requires
  `owner` and `repo` as non-empty strings via `fetch_string/2`, returning a
  precise `%Error{kind: :config_missing}` (with a remediation message) when
  either is absent. Every callback threads through `with {:ok, cfg} <-
  Config.resolve()`, so a missing owner/repo fails fast rather than building a
  malformed URL. `active_repo_slug/0` gives `link_for/1` the slug without a
  full resolve. Tested via the `config_missing` cases.
- [x] **HTTP stubbing in place** — `stub_opts/0` (github.ex:330) injects
  `plug: {Req.Test, Arbiter.Mergers.Github.HTTP}` only when
  `Application.get_env(:arbiter, :github_http_stub, false)` is true, which
  `config/test.exs:18` sets. The adapter never reaches a live endpoint from
  tests; every test installs a `Req.Test.stub/2` that asserts method, path,
  headers, and decoded body. Bearer auth header asserted in `open/4`.
- [x] **Tests comprehensive** — `open/4` (success + reviewer request, opts
  override for target_branch/reviewer_ids/draft, no-reviewers path, 422
  validation error, config_missing); `get/1` (open+approved, merged,
  closed-not-merged, CHANGES_REQUESTED, 404); `merge/1` (squash body, 405
  not_mergeable, 409 conflict, rebase override); `close/1`; `add_comment/2`;
  `request_review/2` (+ empty no-op with no stub installed); `link_for/1`
  (+ fallback); `Mergers.for_strategy(:github)` integration; `with_workspace/2`
  scope-and-restore. Workspace suite adds github-strategy create, the
  `valid_merger_strategies/0` assertion, and `merger_strategy/1` resolution.

## Findings

### Required (must address before merge)

_None._

### Suggested (nice to have — file follow-up beads, do not block this PR)

- **github.ex:236 `approved?/1` uses all review rows, not latest-per-author.**
  GitHub's reviews endpoint returns every review event, including superseded
  ones. If an author requests changes and later approves, both rows remain, so
  this reads as not-approved even though GitHub's own UI (which collapses to the
  latest review per author) would show it approved. This faithfully implements
  the bead's stated contract ("at least one APPROVED and no CHANGES_REQUESTED"),
  so it is correct as specified — but worth a follow-up bead to reduce per
  author to the most recent review if the merge gate ever proves too sticky in
  practice.
- **github.ex:200 reviewer-request failures on open are silently swallowed.**
  `maybe_request_reviewers/3` discards the result (`_ = do_request_reviewers`)
  so a failed reviewer assignment cannot orphan the freshly-created PR — a sound
  trade-off, and documented. The only cost is that the failure is invisible;
  a future `Logger.warning` on the dropped error would aid debugging without
  changing the contract.
- **github.ex:172 `link_for/1` fabricates a placeholder URL when no workspace
  is set** (`https://github.com/owner/repo/pull/<n>`) rather than returning `""`
  like `Direct.link_for/1`. Harmless and tested, but a literal `owner/repo`
  link is mildly misleading; an empty string or the bare `#<n>` might read
  better for the no-config branch.
- **workspace.ex carries incidental Ash-DSL reformatting** (≈32 lines flipped
  from paren-laden back to paren-free). This *restores* `main`'s canonical
  `Spark.Formatter` style — the drift originated on the stacked base branch
  (bd-1qx1nt) — so it is a correction, not a regression, and `mix format
  --check-formatted` is clean. Noting only that the churn ideally belonged in
  the base PR; it inflates this diff with unrelated lines.

### Praise (good patterns to keep)

- Disciplined fidelity to the `Trackers.Jira` shape: same `Config` resolution
  order, same `with_workspace/2` save-and-restore, same `Error` struct vocab.
  The merger and tracker sides now read identically, which is exactly the kind
  of consistency that makes the next adapter (GitLab) cheap to add.
- The `mr_ref`-as-opaque-`"#42"` decision keeps PR-local data in the ref and
  everything workspace-scoped in config — the moduledoc spells this out with a
  worked rationale.
- Status disambiguation (`pr_status/1`) correctly distinguishes a merged-closed
  PR from a plain-closed one via `merged`/`merged_at` before falling back to
  `state`, and the ordered function clauses make the precedence obvious.
- Error mapping is exhaustive and semantic (401→unauthenticated,
  403→forbidden, 404→not_found, 405→not_mergeable, 409→conflict,
  400/422→validation_failed, 5xx→server_error), with `error_message/2`
  surfacing GitHub's own `"message"` when present.
- Tests assert request *bodies* (decoded JSON) and the Bearer header, not just
  status codes — they would catch a payload-shape regression, not merely a
  routing one.

## Code quality checks

- [x] `mix compile --warnings-as-errors` clean (forced recompile, exit 0)
- [x] `mix test` green — 43 tests, 0 failures across `github_test.exs` and
  `workspace_test.exs`
- [x] `mix format --check-formatted` clean on all new + modified files (run
  from the app dir so `Spark.Formatter` loads; exit 0)
- [ ] `mix credo --strict` — N/A (credo is not a dependency in this project)
- [ ] `mix dialyzer` — N/A (not configured)
- [x] No new TODO comments without bead references
- [x] Acceptance criteria covered by tests

## Verdict

**APPROVED** — all five bead criteria verified against the code and a re-run
gate suite (compile clean, 43 tests 0 failures, format clean); four
non-blocking suggestions noted, none of which gate the merge.
