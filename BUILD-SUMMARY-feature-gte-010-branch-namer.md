# Build summary: feature/gte-010-branch-namer

**Bead:** gte-010
**Builder:** Mayor (interactive session, 2026-05-19)
**Branch:** feature/gte-010-branch-namer
**Commit:** 1c5a1b7 (impl + tests)

## What I built

A pure-logic module `Arbiter.Polecat.BranchNamer` that derives a git branch
name from a `Arbiter.Beads.Issue`, following the Verus repo naming
convention.

### Public API

```elixir
Arbiter.Polecat.BranchNamer.derive(%Arbiter.Beads.Issue{}) :: String.t()
```

Returns strings like:

```
feature/VR-17585-add-monitor-controller-tests
bugfix/VR-17612-fix-token-refresh-race
epic/VR-17000-migrate-to-elixir
chore/gte-010-branch-namer-module
```

### Files added

```
apps/arbiter/lib/arbiter/polecat/branch_namer.ex            (+) 99 LOC
apps/arbiter/test/arbiter/polecat/branch_namer_test.exs     (+) 18 tests
```

The `polecat/` namespace did not exist before this bead; it now hosts this
module. gte-009 (parallel) will add `Polecat.Worktree` alongside.

## Acceptance check (from bead gte-010)

| Criterion | Status |
|---|---|
| `:bug` → `bugfix/VR-#####-slug` | covered by `branch_namer_test.exs` "derive/1 prefix mapping" describe block |
| `:feature`, `:task` → `feature/VR-#####-slug` | same |
| `:epic` → `epic/VR-#####-slug` | same |
| Slug: lowercase, hyphenated, drop articles, max 6 words | covered by "derive/1 slug derivation" describe block |
| Configurable per workspace via vernacular | **deferred to gte-P2** — prefix mapping is currently a private function `prefix_for/1`. Vernacular module hasn't shipped yet. Trivial to swap once it does. |
| Tested against ~10 example titles + types | 18 tests, comfortably exceeds |
| VR-##### extracted from external_ref (jira-VR-#####) when present | the import script (gte-007) already parses `jira-VR-17585` into `tracker_type=:jira, tracker_ref="VR-17585"`, so this module just reads `issue.tracker_ref`. No re-parsing here. |

## Design choices worth flagging

1. **Stopword list is small and ASCII-only.** Articles per spec
   (`a`, `an`, `the`) plus seven common particles (`of`, `to`, `for`, `and`,
   `or`, `in`, `on`, `with`). Anything else — including English content words
   that happen to be filler — is preserved. The intent is for the slug to
   stay informative; aggressive stopword filtering would drop signal. The
   list is a module attribute (`@stopwords`), easy to lift into Vernacular
   config later.

2. **`:chore` and `:decision` map to `chore/`.** The bead spec only covered
   `:bug`, `:feature`, `:task`, `:epic`. The Issue resource defines six
   `issue_types`, and leaving two unmapped would make `derive/1` partial.
   `chore/` is the natural bucket — Verus's convention has `chore/` for
   non-feature non-bug branches. If product decides differently later, change
   one line.

3. **Total length capped at 60 chars; slug truncated, not prefix or ref.**
   Anchor the meaningful identifiers (`feature/VR-17585-`) and trim the
   slug from the right. Trailing `-` from a mid-word cut is stripped. 60
   was picked to keep branches comfortable in CLI tools without being so
   tight that normal slugs get clipped. (A 6-word slug of typical English
   averages ~35 chars; the cap only bites on pathological single-word
   titles.)

4. **Total function, raises only on truly malformed input.** Missing
   `tracker_ref` falls back to `issue.id`; missing/blank title falls back
   to `"untitled"`. The only raises are: non-Issue input, unknown
   `issue_type` atom, or both `id` and `tracker_ref` absent (impossible
   for a persisted Issue).

5. **Pure-function tests build Issues via `struct/2`,** not Ash actions.
   No DB, no Ash overhead. `async: true`. The tests run in 50ms.

## What I punted on (with reasons)

1. **Vernacular-driven prefix/stopword overrides.** Hooks are in place
   (`prefix_for/1`, `@stopwords`), but reading from `Workspace.config`
   requires the Vernacular module (gte-P2) which hasn't landed. File a
   follow-up bead once gte-P2 ships to swap the hard-coded values for
   `Vernacular.fetch/2` calls.

2. **Collision detection.** Two issues with identical titles + identical
   refs would produce the same branch name. Not in scope for a pure
   derivation function — the caller (Polecat orchestration, gte-011+) is
   responsible for handling existing branches.

3. **Disambiguation between workspaces.** A `gte-010` and a `bd-010` in
   different workspaces would both produce `*/gte-010-...` and
   `*/bd-010-...` respectively, so the workspace prefix in the issue id
   already disambiguates the fallback. No special handling needed.

## How to verify

```sh
cd ~/dev/arbiter-wt-010

mix compile --warnings-as-errors    # clean
mix test apps/arbiter/test/arbiter/polecat/branch_namer_test.exs
# Expect: 18 tests, 0 failures

mix test
# Expect: 48 (cli) + 124 (arbiter, +18) + 36 (web) = 208 tests, 0 failures
```

`mix format --check-formatted` on the repo as a whole is **not** clean — but
those are pre-existing issues in `mapper_test.exs` and similar, untouched by
this branch. My two files pass `mix format --check-formatted` cleanly.

## Verdict requested

Ready to review. Reviewer should sanity-check:

- The stopword list (`@stopwords`) — is the seven-particle extension to the
  spec's "drop articles" reasonable, or should we go strictly articles-only?
- The `:chore` / `:decision` → `chore/` mapping — confirm with product /
  Verus convention.
- The 60-char total-length cap — is that the right number? Some teams use
  80 for branch names; git itself has no real limit but some CI systems
  truncate at 63.

After merge: gte-011 (Polecat orchestrator) can start consuming this.
