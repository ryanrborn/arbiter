# BUILD-SUMMARY: gte-021 — Workflows.CodeReview (peer review)

## Branch

`feature/gte-021-code-review` off `78b8c2e` (main / gte-029).

## What shipped

A new `Arbiter.Workflows.CodeReview` workflow driven by
`Arbiter.Workflow.run/2` (and dispatchable through the gte-015
WorkflowMachine). Five steps:

| Step              | Needs           | Effect                                                 |
| ----------------- | --------------- | ------------------------------------------------------ |
| `:load_pr`        | —               | Records branch (local) or loads PR via `GitHub.pr_get` |
| `:read_diff`      | `:load_pr`      | Runs `git -C <wt> diff <base>..HEAD`                   |
| `:run_checks`     | `:read_diff`    | Invokes `state[:check_runner]` or default no-op        |
| `:file_findings`  | `:run_checks`   | Writes `reviews/<branch>.md` (local) or posts comments |
| `:verdict`        | `:file_findings`| Computes :approve / :request_changes; finalizes        |

Two modes, selected by `state.mode`:

  * `:local`  — writes `<worktree>/reviews/<sanitized-branch>.md`
  * `:github` — posts inline comments + a summary comment + a top-level
    review verdict via the typed `Arbiter.GitHub` HTTP client. No
    `gh` shell-out.

## Files

  * `apps/arbiter/lib/arbiter/workflows/code_review.ex` — workflow
    module, step dispatch, verdict computation.
  * `apps/arbiter/lib/arbiter/workflows/code_review/checks.ex` —
    default check runner (Phase 2: returns `{:ok, []}`).
  * `apps/arbiter/lib/arbiter/workflows/code_review/local_mode.ex` —
    review-file rendering & verdict-line rewrite.
  * `apps/arbiter/lib/arbiter/workflows/code_review/github_mode.ex` —
    inline-comment loop, summary comment, review verdict.
  * `apps/arbiter/lib/arbiter/github.ex` — adds
    `Arbiter.GitHub.pr_review/5` (`POST /repos/:o/:r/pulls/:n/reviews`).
  * `apps/arbiter/test/arbiter/workflows/code_review_test.exs` —
    23 tests.

## New GitHub function: `pr_review/5`

```elixir
@spec pr_review(repo, pr_number, :approve | :request_changes | :comment,
                String.t(), keyword()) :: result(map())
```

Maps the Elixir atom event to GitHub's `APPROVE` / `REQUEST_CHANGES` /
`COMMENT` strings and POSTs to the reviews endpoint. Tested with two
unit tests that assert request payload + path (one for approve, one for
request_changes). Approve-with-empty-body works because GitHub accepts
`body: ""` for `APPROVE`.

This is the typed replacement for the Go GT's `gh pr review --approve`
shell-out and replaces the "Phase 2 fallback to pr_comment" gap the
spec called out.

## Review file format (local mode)

Mirrors the polecat-reviewer convention from the Go GT — header, task
reference, pending verdict line that is rewritten in place by `:verdict`,
then findings ordered by severity (error > warning > info), then file,
then line. Example:

```
# Code review: feature/x

**Task:** gte-021 — code review
**Mode:** local
**Verdict:** APPROVE

## Findings

(2 findings)

### lib/foo.ex:10 — error
boom

### lib/bar.ex:3 — info
fyi
```

Branch names with `/` are sanitized to `-` in the filename (e.g.
`feature/x` → `reviews/feature-x.md`).

## Extension hook: `:check_runner`

`run_step(:run_checks, state)` reads `state[:check_runner]`, falling back
to `&Checks.run/2` (the Phase-2 no-op). The runner is a 2-arity function
`(diff, state) -> {:ok, [finding]} | {:error, term}`. Findings are maps
of shape `%{severity: :info|:warning|:error, file: String.t(),
line: pos_integer(), message: String.t()}`.

I chose a state-borne hook over a module attribute because the
workflow runs once per polecat-session and the runner needs to vary
per workspace/task anyway. Tests inject stubs via this hook without
mocking modules.

## Forbidden actions

The reviewer polecat MUST NOT push code or merge PRs. Enforcement is
**static** — the workflow source simply does not call
`Arbiter.Polecat.Worktree.push/2` or `Arbiter.GitHub.pr_merge/4`.
A regression test (`module does not call GitHub.pr_merge or
Polecat.Worktree.push`) reads the source, strips the moduledoc, and
asserts neither symbol appears in the remaining code. Cheap, deterministic,
no xref dependency.

The moduledoc documents the constraint and points unsure reviewers at
the Mayor for escalation (via the surrounding polecat orchestration —
the workflow itself just produces a verdict).

## Tests

23 tests, all green. Coverage:

  * Workflow declaration (steps order, vars, step_definition shape,
    forbidden-actions source check) — 5 tests
  * `:load_pr` local + github + bad-state — 3 tests
  * `:read_diff` happy + bad-state — 2 tests
  * `:run_checks` default + injected runner + error propagation — 3 tests
  * `:file_findings` local file contents + github stub round-trip — 2 tests
  * `:verdict` no-findings → :approve, error → :request_changes,
    warnings-only → :approve, github stub round-trip — 4 tests
  * End-to-end via `Arbiter.Workflow.run(CodeReview, ...)` in local mode — 1
  * `GitHub.pr_review/5` (approve, request_changes) — 2 tests
  * `Checks.run/2` Phase-2 no-op — 1 test

Full umbrella: 67 + 335 + 36 = **438 tests, 0 failures**.

## Follow-ups (not in this PR)

  1. **Real check execution.** Implement a meaningful default runner that
     reads the task's acceptance criteria and runs lint / type checks
     against the diff. The hook is in place; the policy is not.
  2. **`pr_resolve_thread/3` integration.** A reviewer that approves
     should arguably mark prior request-changes threads resolved on
     re-review. Not in scope for gte-021; revisit when polecat handles
     re-review loops.
  3. **Commit_id discovery for inline comments.** Github-mode currently
     either accepts `commit_id` via `github_opts` or relies on
     `GitHub.pr_inline_comment/6`'s built-in pre-fetch (one extra GET
     per finding). Future: fetch once in `:load_pr` and pass it through.
  4. **Idle transition.** The workflow does not drive polecat state;
     the surrounding orchestration is responsible for transitioning back
     to `:idle` after `:verdict`. Confirm this is wired correctly when
     the polecat-orchestrator wraps the workflow (gte-024 area).

## Constraints honored

  * No merge, no push from the worktree.
  * Two commits (impl + this BUILD-SUMMARY), conventional prefix.
  * No `--no-verify`.
  * No edits in the main repo at `/home/rborn/dev/arbiter/`.
