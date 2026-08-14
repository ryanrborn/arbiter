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
caller is never starved. The patrols and the record sweeps (`PRPatrol`,
`ReviewPatrol`, `MergeQueue`, `PrStatePoller`, `MergedPRFinalizer`) wrap their
poll body in `with_priority(:background, ...)`; everything else (dispatch,
tracker transitions, PR open/merge/finalize) runs foreground by default.

> **The class lives in the process dictionary and does not cross a process
> boundary.** Handing GitHub work to a spawned `Task` reverts it to the
> `:foreground` default, so a background sweep that fans out over
> `Task.start/1` silently reclassifies itself as foreground. Use
> `Limiter.start_task/2` for that (bd-8y1i58 — this is exactly how the
> dashboard's Review History refresh became a foreground firehose).

## The idle floor

With no work in flight — zero workers, zero ready tasks, empty mailbox — the
fleet's GitHub traffic should be **near zero**, and in particular must not scale
with the size of the open backlog. Two sweeps walk stored records rather than
work in flight and so are the ones that can violate this:

- `PrStatePoller` — bounded by `:fetch_limit` (500) per cycle and
  `:max_checks_per_cycle` (25) per cycle actually re-resolved, and each record
  carries its own backing-off cadence (below).
- `MergedPRFinalizer` — bounded by `:merged_pr_finalizer_max_checks_per_tick`
  (25) with a rolling cursor, so a large backlog is swept over successive ticks
  instead of all at once. Note one `adapter.get/1` costs *two* GitHub calls (the
  PR, then its reviews).

`Arbiter.GitHub.IdleFloorTest` locks all three invariants down: nothing in
flight issues zero traffic, a backlog is swept entirely as background, and a
settled backlog decays toward zero.

### "Idle" is about time, not backlog size (bd-7qgxf9)

The first version of this floor read "no work in flight" as "no *non-terminal
records*", which is not what an idle installation looks like. A long-lived
install carries a standing population of review records whose PR is simply
still `open`, plus rows parked at `unknown` after a token blip — none of them
work in flight, all of them non-terminal. `PrStatePoller` re-resolved every one
on every cycle, so its cost was a flat function of *history*: ~30 such records
measured as ~1,776 calls/hour (~36% of the 5,000/hr account budget) on a fleet
with zero workers and zero ready issues.

So the poller now paces **per record** rather than globally. A check that finds
the state unchanged — or that fails, which is no evidence of change — doubles
that record's personal interval, from `:interval_ms` up to
`:backoff_ceiling_ms`; a check that finds a real transition resets it to the
base, so a PR that is actually moving is followed closely again immediately. A
settled record costs ~6 calls in its first hour and one per ceiling after that,
and the floor decays toward zero no matter how much history the install
carries.

The cadence lives in the poller's memory, not on the row: a restart is worth
one full re-sweep (which is also a useful re-verification after downtime) and
then decays again within minutes — not worth a migration or a DB write per
skipped record.

## Observability

`Limiter.stats/0` returns per-pool counters (`foreground`, `foreground_paused`,
`background`, `background_paused`, `secondary_trips`, `by_subsystem`) and the
last-seen numbers. The limiter also logs a summary line periodically, so the
next incident is diagnosable from the server rather than by sampling GitHub
from a laptop.

Allowed background calls are attributed to the subsystem that issued them, and
the periodic line carries the breakdown biggest-spender-first:

    GitHub limiter: {:account, "leo"} remaining=4407 fg=0 fg_paused=0
      bg=443 (pr_state_poller=380 pr_patrol=51 merge_queue=12) bg_paused=0
      secondary_trips=0

Tag a new background caller by using `Limiter.with_priority/3` instead of
`/2`; untagged background traffic is still counted, under `:unattributed`.
Only *allowed* calls are attributed, so the breakdown sums to `bg` exactly.

Every real HTTP request is gated exactly once — including each attempt of the
merger's bounded secondary-limit retry — so the counters reflect calls actually
issued rather than call *sites* entered.

### `bg_paused` is an exhaustion valve, not a throttle

Every reason background can be withheld — `:background_headroom`,
`:foreground_reserve`, a secondary-limit cooldown — is a signal that the
account is near the bottom of its budget. So a healthy account burning steadily
while idle shows `bg_paused` frozen at zero, and that is correct rather than a
sign the mechanism is broken. Pacing is the pollers' job: the limiter only ever
sees a request after its caller has already decided to make it.

## Configuration (application env, `:arbiter`)

| Key | Default | Meaning |
| --- | --- | --- |
| `:github_limiter_background_headroom` | `1000` | Remaining primary quota at/below which background traffic pauses. |
| `:github_limiter_foreground_reserve` | `0` (off) | Remaining primary quota at/below which **all** arbiter traffic stops, foreground included. See below. |
| `:github_limiter_secondary_cooldown_ms` | `120_000` | How long background stays fully paused after a secondary-limit hit (re-armed on each hit). |
| `:github_limiter_probe` | `true` (`false` in test) | Whether to resolve owning accounts (`GET /user`) and poll the exempt `/rate_limit` endpoint. |
| `:merged_pr_finalizer_max_checks_per_tick` | `25` | Tasks the merged-PR sweep checks per tick (non-positive disables the cap). |

`PrStatePoller` is configured separately, under `config :arbiter, :pr_state_poller`:

| Key | Default | Meaning |
| --- | --- | --- |
| `:interval_ms` | `60_000` | Cycle interval, and the base of each record's backoff. |
| `:fetch_limit` | `500` | Non-terminal records scanned (DB only) per cycle. |
| `:backoff_ceiling_ms` | `3_600_000` | Longest a settled record's own interval may grow to. |
| `:max_checks_per_cycle` | `25` | Records actually re-resolved per cycle, most-overdue first. |

### The foreground reserve

Foreground being un-throttleable protects arbiter's own work, but GitHub meters
per *user* across every token: an arbiter that spends the pool to zero starves
the operator's interactive `gh`, unrelated CI, and every other tool on the
account — a separate PAT buys no relief. The reserve puts a hard floor under
that: at or below `remaining`, arbiter stops issuing entirely, leaving the band
for a human.

It is **off by default**. Below a nearly-exhausted pool a foreground call would
very likely 403 anyway, but the limiter should not be the thing that fails a
deploy unless the operator has asked for that trade. Enable with:

    config :arbiter, :github_limiter_foreground_reserve, 500

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
