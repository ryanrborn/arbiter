# Review: feature/bd-1qx1nt-define-merger-behaviour-direct-adapter

**Bead:** bd-1qx1nt (reviewed under bd-3h0706)
**Builder:** polecat (PR #9, commit fb4dd03)
**Reviewer:** polecat (bd-3h0706)
**Date:** 2026-05-28 17:35

## Diff summary

Establishes the `Merger` abstraction, mirroring the existing `Tracker` abstraction:
a behaviour (`Arbiter.Mergers.Merger`), a dispatcher (`Arbiter.Mergers`) that resolves
the adapter from `workspace.config["merge"]["strategy"]`, and the first adapter
(`Arbiter.Mergers.Direct`), which performs a local `git merge --no-ff` immediately with
no MR or review gate. Workspace gains `valid_merger_strategies/0` (`~w(direct)`) and
`merger_strategy/1`; `ValidateConfig` gains a `merge.strategy` enum check using a runtime
if-check. Tests cover the direct merge path against a real temp git repo plus the no-op
callbacks and workspace wiring. Incidentally fixes a stale `valid_tracker_types/0` test
assertion left over from the `:shortcut` addition.

## Acceptance criteria check

- [x] **Behaviour contract is clean and complete** — all 7 callbacks present
  (`open/4`, `get/1`, `merge/1`, `close/1`, `add_comment/2`, `request_review/2`,
  `link_for/1`) with types matching the bead spec exactly. `mr_ref` typed as an opaque
  `String.t()`. `opts` keys (`:target_branch`, `:reviewer_ids`, `:labels`) documented.
- [x] **Direct adapter is a correct no-op** — `get/1` → `{:ok, %{status: :merged}}`;
  `merge/1`/`close/1`/`add_comment/2`/`request_review/2` → `:ok`; `link_for/1` → `""`.
  `open/4` checks out the target then runs `git merge --no-ff`, returning
  `{:ok, "direct:<branch>"}`. Matches the spec precisely.
- [x] **ValidateConfig uses a runtime if-check, not a guard** — the only guard is
  `is_map(merge)`; the strategy is validated with `if strategy in valid_strategies`,
  matching the recent `tracker.type` fix shape (validate_config.ex:88).
- [x] **valid_merger_strategies/0 is wired consistently** — defined once on `Workspace`
  (`@valid_merger_strategies ~w(direct)`); `ValidateConfig` reads it via the public
  function; `merger_strategy/1` reads the same source. No drift.
- [x] **Tests cover the direct merge path against a real temp repo** — `direct_test.exs`
  uses `@tag :tmp_dir` and `System.cmd/3` to build a real repo, then asserts the merge
  commit has two parents (proving `--no-ff`), HEAD returns to `main`, the `-m` message
  is applied, plus missing-branch and missing-`repo_path` error paths, the no-op
  callbacks, and the behaviour declaration.

## Findings

### Required (must address before merge)

_None._

### Suggested (nice to have — file follow-up beads, do not block this PR)

- **direct.ex:31-39 — `open/4` leaves the rig in a conflicted/merging state on failure.**
  On a merge conflict (or any non-zero `git merge`), `run_git` returns
  `{:error, {:git_failed, _}}`, but the working tree is left mid-merge on `target_branch`
  with the original branch un-restored. Nothing runs `git merge --abort` or restores the
  prior HEAD. For the personal-project happy path this is acceptable and within the bead's
  stated scope, but a real rig could be left dirty for the next operation. Worth a
  follow-up bead to add conflict cleanup / branch restoration once mergers are wired into
  the actual merge flow.
- **mergers.ex:46-56 — `for_strategy/1`'s raise is currently unreachable via
  `for_workspace/1`.** `merger_strategy/1` only ever returns a strategy in
  `valid_merger_strategies/0` (or the `:direct` fallback), and `@adapters` covers `:direct`,
  so the `ArgumentError` branch can only fire on a direct `for_strategy/1` call. This is
  fine — it's a sensible guard against `@adapters`/`valid_merger_strategies` drift as
  `:gitlab`/`:github` land — just noting the two lists must be kept in lockstep then.
- **validate_config.ex moduledoc (pre-existing, out of scope)** — the tracker-types list
  in the moduledoc still reads `"none", "jira", "linear", "github"` and omits `"shortcut"`.
  Not introduced by this PR, but adjacent; fold into the next workspace-config touch.

### Praise (good patterns to keep)

- The behaviour moduledoc is exemplary: documents `mr_ref` opacity with per-adapter
  examples, the `opts` contract, and per-callback semantics. Future GitLab/GitHub adapters
  have a clear contract to implement against.
- `run_git/2` rescuing `ErlangError` so a missing `git` on `PATH` degrades to
  `{:error, {:git_failed, _}}` instead of crashing the caller — thoughtful.
- The `--no-ff` two-parent assertion (`rev-list --parents`) is a precise, behavioural way
  to prove the no-fast-forward merge actually happened rather than just checking file
  presence.
- Cleanly mirrors the `Trackers` abstraction, keeping the codebase's adapter pattern
  consistent.

## Code quality checks

- [x] `mix compile --warnings-as-errors` clean
- [x] `mix test` green — 27 tests, 0 failures across both touched suites
- [x] `mix format --check-formatted` — the new files (mergers.ex, direct.ex, merger.ex,
  validate_config.ex) are clean. workspace.ex flags only on pre-existing Ash DSL lines;
  20 untouched files across the repo flag identically, confirming a local `Spark.Formatter`
  environment artifact (plugin lacks compiled-extension context in a fresh worktree), not a
  defect in this PR.
- [ ] `mix credo --strict` — N/A (credo is not a dependency in this project)
- [ ] `mix dialyzer` — N/A (not configured)
- [x] No new TODO comments without bead references
- [x] Acceptance criteria covered by tests

## Verdict

**APPROVED**

The behaviour contract, Direct no-op, runtime if-check, and `valid_merger_strategies/0`
wiring all match the bead spec exactly, with comprehensive tests against a real temp repo;
the only findings are non-blocking follow-ups (conflict cleanup, a doc nit).
