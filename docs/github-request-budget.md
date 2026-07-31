# GitHub request budget (priority-aware limiter)

`Arbiter.GitHub.Limiter` is a shared, priority-aware budget that governs every
GitHub-calling path in the fleet (`Arbiter.GitHub`, `Arbiter.Mergers.Github`,
`Arbiter.Trackers.GitHub`). It exists to stop low-value **background** traffic
(patrol polling, speculative refreshes) from starving high-value **foreground**
work (a `server deploy`, a dispatch, a PR open/merge/finalize, a tracker
transition, or a human debugging by hand). Tracking: `bd-3p5vqc`.

## The one fact that shapes everything: it's one pool

GitHub accounts its primary quota (~5,000 REST req/hr, plus the GraphQL points
budget) **per owning account** — not per token. Every Personal Access Token
owned by the same account draws from **one** pool, and so does the operator's
interactive `gh`. A separate PAT does *not* buy a separate pool (empirically
confirmed 2026-07-31: arbiter's own PAT shares the operator's pool). Only a
GitHub **App installation** or a distinct **machine-user account** would add a
genuinely separate pool.

Two consequences:

1. **The limiter is keyed on a _pool identity_, not a credential string.** For a
   PAT the pool is the owning account, resolved via `GET /user` and cached. Two
   different PATs owned by the same account share one budget. When the owner
   can't be established, the credential maps to the `:shared` pool — we **fail
   safe toward shared**, because wrongly assuming *separate* pools over-issues
   and starves foreground work, whereas wrongly assuming *shared* merely
   under-issues.

2. **The operator's interactive `gh` is invisible to the limiter** — it runs
   outside arbiter entirely. Because that traffic can't be accounted, **precise
   accounting is impossible**; reserving headroom is the only workable strategy.

## Strategy: reserve headroom, back off hard on secondary limits

- **Foreground is never throttled.** `acquire/3` always returns `:ok` for
  foreground, even at zero headroom or during a secondary backoff. A foreground
  call may still 403 on its own, but the limiter is never the reason a deploy
  fails.
- **Background pauses below a reserved headroom band.** Once remaining primary
  quota falls to/below `background_headroom`, background traffic pauses entirely
  (it does not degrade gracefully), leaving the band for foreground and the
  human's `gh`.
- **Secondary (abuse) limits → back off hard.** GitHub's secondary limit is
  separate and invisible: a 403 can occur while `/rate_limit` still reports
  thousands remaining, and it only clears with genuine quiet — retry traffic is
  what sustains it. A "403 with headroom showing" arms a cooldown during which
  background is fully paused, rather than being retried soon.

The limiter is driven by GitHub's **real numbers**: every response's
`x-ratelimit-*` headers are fed back for free on each call, and (when probing is
enabled) the **exempt** `/rate_limit` endpoint is polled periodically so the
numbers stay fresh even when the fleet is idle — at zero quota cost.

## Priority classes and how a caller is tagged

The ambient class for a process is set with `Limiter.with_priority/2` and read
with `Limiter.current_priority/0`. The default is `:foreground` — an un-tagged
caller is never starved. The two patrols (`PRPatrol`, `ReviewPatrol`) wrap their
poll body in `with_priority(:background, ...)`; everything else (merge queue,
dispatch, tracker transitions) runs foreground by default.

## Observability

`Limiter.stats/0` returns per-pool counters (`foreground`, `background`,
`background_paused`, `secondary_trips`) and the last-seen numbers. The limiter
also logs a summary line periodically, so the next incident is diagnosable from
the server rather than by sampling GitHub from a laptop.

## Configuration (application env, `:arbiter`)

| Key | Default | Meaning |
| --- | --- | --- |
| `:github_limiter_background_headroom` | `1000` | Remaining primary quota at/below which background traffic pauses. |
| `:github_limiter_secondary_cooldown_ms` | `120_000` | How long background stays fully paused after a secondary-limit hit (re-armed on each hit). |
| `:github_limiter_probe` | `true` (`false` in test) | Whether to resolve owning accounts (`GET /user`) and poll the exempt `/rate_limit` endpoint. |

The limiter **fails open**: if it is not running, the request seam lets traffic
through untouched — it is a protection layer, not a correctness gate.

## Adopting a GitHub App later

Nothing here hardcodes the pool count. If a GitHub App installation is adopted,
its credential resolves to its own `{:account, login}` pool with its own
(larger, installation-scaled) budget, and the limiter models it as a genuinely
separate pool with no redesign — while today's single-pool reality stays
correct.

## Related

- `bd-3byp1n` (#1076) — batch patrol forge queries: reduces background spend at
  the source; this caps it.
- `bd-7tr11p` — lazy patrol lifecycle: reduces background spend at the source.
- `bd-1m8k7d` (#1002) — ReviewPatrol rate-limit circuit breaker: one caller
  hitting a limit; this is system-wide prioritisation.
- `bd-2wilou` (#1023) — tracker-sync retry/backoff: symptom vs. allocation.
- `bd-4jcf3m` — dedicated arbiter credential: worth doing for credential
  hygiene, but does **not** relieve pool contention (it shares the pool).
