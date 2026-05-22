# Build summary: feature/gte-018-github

**Bead:** gte-018
**Builder:** Mayor (interactive session, 2026-05-19)
**Branch:** feature/gte-018-github
**Commit:** 53e3f47 (impl + tests)

## What I built

`Arbiter.GitHub` — a Req-backed HTTP wrapper around the GitHub REST API
(plus one GraphQL mutation for `resolveReviewThread`) covering the seven
operations the future polecat-orchestrator needs.

### Public API

```elixir
Arbiter.GitHub.pr_open(repo, branch, target, title, body, opts \\ [])
Arbiter.GitHub.pr_get(repo, pr_number, opts \\ [])
Arbiter.GitHub.pr_list_reviews(repo, pr_number, opts \\ [])
Arbiter.GitHub.pr_comment(repo, pr_number, body, opts \\ [])
Arbiter.GitHub.pr_inline_comment(repo, pr_number, path, line, body, opts \\ [])
Arbiter.GitHub.pr_resolve_thread(repo, thread_id, opts \\ [])
Arbiter.GitHub.pr_merge(repo, pr_number, strategy, opts \\ [])
Arbiter.GitHub.rate_limit()
```

Every public function returns `{:ok, value}` or `{:error, %Arbiter.GitHub.Error{}}`.

### Files added

```
apps/arbiter/lib/arbiter/github.ex             (+) ~330 LOC
apps/arbiter/lib/arbiter/github/error.ex       (+)  ~40 LOC
apps/arbiter/test/arbiter/github_test.exs      (+) 19 tests
apps/arbiter/test/test_helper.exs                (M) ensure :req started
config/test.exs                                    (M) :github_http_stub flag
```

## Acceptance check (from bead gte-018)

| Criterion | Status |
|---|---|
| Module GitHub using Req with seven listed functions | covered |
| Token from env | `System.get_env("GITHUB_TOKEN")` lazy, opts[:token] override |
| Rate-limit aware (uses GH headers) | every response (success + error) updates `:persistent_term` cache; `rate_limit/0` reads it |
| Tested against a real repo (could be a fixture personal repo) | **deferred** — bead Phase 2 is module surface only. Tests use `Req.Test` stubs; a real-repo smoke test belongs with gte-020/021/022 when there's actual orchestration to exercise. Flagging for reviewer to confirm. |
| Errors are structured tagged tuples | `{:error, %Arbiter.GitHub.Error{kind, status, message, raw}}` |

## Design choices worth flagging

1. **Rate-limit storage: `:persistent_term`, not return-value.** Returning
   `{:ok, value, %{rate_limit: ...}}` on every call would force every
   call-site to pattern-match on a three-tuple just to get the payload.
   `:persistent_term` is VM-global, lock-free reads, perfect for
   monotonically-updated state. The cost is that the test suite is
   `async: false` (otherwise parallel tests in the same module race on
   the `rate_limit/0 is nil` setup). This is documented at the top of
   the test module. An ETS-table alternative would be process-supervised
   and async-friendly but more setup; `:persistent_term` is the right
   call for a wrapper that may be invoked from many processes.

2. **Error.kind enum is tight.** `:unauthenticated | :forbidden |
   :not_found | :validation_failed | :server_error | :http | :network`.
   I considered separating `:rate_limited` (403 with a specific header)
   from generic `:forbidden`, but GitHub uses 403 for both
   permission-denied and rate-limit-exceeded, and the
   `x-ratelimit-remaining` value distinguishes them. Callers wanting
   that nuance read `rate_limit/0` after the error. Keeping `:http` as
   a catch-all for unexpected 4xx (e.g. 451) means future codes don't
   need module changes.

3. **GraphQL asymmetry for `pr_resolve_thread`.** REST has no thread
   resolution endpoint. The function POSTs the `resolveReviewThread`
   mutation to `/graphql` with the thread node ID as variable. GraphQL
   200-OK-with-`errors` is mapped to `{:error, %Error{kind:
   :validation_failed}}` — not `:http`, because it *is* a request-shape
   problem, not a transport problem. The message is the first GraphQL
   error's `message`; the full errors array is in `raw`.

4. **`:unauthenticated` (missing token) raises ArgumentError.** Per the
   spec recommendation. A missing token is a deployment / programmer
   error, not a runtime failure mode — there's no recovery path for the
   caller, so a clear crash at the call site is better than a tagged
   tuple that callers might pattern-match-and-retry on. The runtime
   401 from GitHub (bad credentials) does map to
   `{:error, %Error{kind: :unauthenticated}}` — those two cases are
   distinct.

5. **`pr_inline_comment` fetches the head SHA when caller doesn't pass
   `:commit_id`.** GitHub requires `commit_id` on inline comments. The
   convenient path is one call; the safe path is one extra GET. I
   default to the safe path and document the optimization. Tests cover
   both branches.

6. **Test stubbing via app-env flag + per-call `:plug` opt.** Setting
   `config :arbiter, :github_http_stub, true` in `config/test.exs`
   makes the module inject `plug: {Req.Test, Arbiter.GitHub.HTTP}`
   into every Req call. Tests register stubs via
   `Req.Test.stub(Arbiter.GitHub.HTTP, fn conn -> ... end)`. The hook
   also accepts an explicit `opts[:plug]` for callers who want to
   override at the call site without changing app env (useful later
   for integration tests).

## What I punted on (with reasons)

1. **Real-repo smoke test.** Bead acceptance says "tested against a
   real repo (could be a fixture personal repo for safety)" — I read
   that as a follow-up acceptance criterion for the orchestrator
   beads (gte-020+), not Phase 2. Adding a smoke test now means a CI
   secret + a real PR being opened-and-closed in a fixture repo every
   build, which is the kind of thing that's better attached to the
   first feature that actually opens PRs end-to-end. File a follow-up
   bead under gte-020 if reviewer wants this sooner.

2. **`reviewDecision` parsing.** `pr_get` returns the REST payload
   verbatim, which does **not** include `reviewDecision` (that field
   is GraphQL-only). The spec lists `reviewDecision` under `pr_get`,
   but exposing it requires a second GraphQL round-trip per call.
   Callers needing it should combine `pr_get` with `pr_list_reviews`
   and infer state, or open a follow-up bead to add a GraphQL variant.

3. **Retry / backoff on 5xx and `:network`.** `retry: false` on every
   call. The orchestrator (gte-020+) is the right layer to decide retry
   policy — it has the context to know whether a transient failure
   should retry, escalate, or give up.

4. **Pagination.** `pr_list_reviews` returns the first page only.
   GitHub paginates at 30 by default. Most PRs have <30 reviews, but a
   long-running PR could exceed it. Add a `:paginate` opt in a follow-up
   if it comes up.

## How to verify

```sh
cd ~/dev/arbiter-wt-018

mix compile --warnings-as-errors    # clean
mix format --check-formatted apps/arbiter/lib/arbiter/github.ex \
  apps/arbiter/lib/arbiter/github/error.ex \
  apps/arbiter/test/arbiter/github_test.exs

mix test apps/arbiter/test/arbiter/github_test.exs
# Expect: 19 tests, 0 failures

mix test
# Expect: 48 (cli) + 170 (arbiter, +19) + 36 (web) = 254 tests, 0 failures
```

## Verdict requested

Ready to review. Reviewer should sanity-check:

- **Rate-limit storage** — `:persistent_term` cache + `rate_limit/0`. Is
  the trade-off (clean API, but VM-global + test suite must be
  async-false within this module) the right one? Alternative is
  returning `{remaining, reset_at}` on each success tuple or running an
  ETS-backed `GenServer`.
- **Error.kind enum boundaries** — particularly that GraphQL 200-with-
  errors collapses into `:validation_failed`, and that 403 is
  `:forbidden` regardless of whether it's a scope problem or a
  rate-limit problem.
- **The `:unauthenticated` raise** — programmer-error semantics, not a
  tagged tuple. Confirm we don't want a tagged tuple here for symmetry.
- **`pr_inline_comment` auto-fetching `commit_id`** — convenient default
  vs. extra round-trip. Worth keeping?
- **Real-repo smoke test deferral** — reasonable to defer to gte-020+?
