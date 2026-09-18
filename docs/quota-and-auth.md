# Quota & Auth Posture

**bd-2jgs2h, 2026-09-18.** Documents how the fleet detects and bounds a dead
credential — and, just as importantly, how it deliberately no longer tries to
predict one.

## Dispatch no longer pre-checks auth

Through 2026-06-05 → 2026-09-18, every real dispatch and every resume paid a
model turn to run a live CLI probe (`Arbiter.Worker.Dispatch.run_preflight/2`,
`Arbiter.Agents.Preflight.check/2`) before spawning the actual worker, purely
to ask "are you logged in?" ahead of time.

The operator retired that probe on 2026-09-18. The evidence, measured from the
live DB and the code on that date:

- **10 auth-failed worker runs in 90 days** (`worker_runs.failure_reason like
  '%authenticate%'`). Half of them died **mid-run**, a shape no pre-flight
  probe — which only ever runs before spawn — could ever have caught. Pre-flight
  had been live the whole 90 days.
- **~760 probes/day** against those 10 failures in 90 days: claude 374/day
  ($4.59/day), codex 319/day (cost not billed to us but still a real request),
  gemini 26/day. Over 7 days: claude 1,762 probes / **$23.27**, codex 1,544,
  gemini 1,257 — about 4,500 billed model turns a week spent asking a question
  a dead credential answers for free.
- **Failing fast is cheap.** Across the auth-failed runs, credentials dead at
  spawn made the CLI exit in **3-5s**; the mid-run deaths took 374-717s and,
  again, were never reachable by a pre-flight probe either way.
- **A rejected request bills nothing at the provider.** The probe does.

So the policy inverted: **dispatch, and react to the provider's own error
instead of paying to guess beforehand.** `Arbiter.Worker.Dispatch.dispatch/2`
still runs a guard ahead of every real-agent dispatch
(`Arbiter.Worker.Dispatch.maybe_preflight/2`), but that guard is now a plain,
free state lookup — `Arbiter.Agents.CredentialWatchdog.expired?/1` — never a
live CLI call. Opt out entirely with `preflight: false`; the guard is also
skipped whenever `start_claude: false` (no real agent about to spawn).

## What bounds a wave of identical failures

Without *something* refusing dispatch once a credential is known-dead, a
single expired token burns the queue at the fleet's normal dispatch rate:
each failed worker frees its slot, the next Ready card promotes, and it
fails again — each pass still leaving a worktree, a branch, a failed run and
an escalation behind it (`cleanup_worktree` defaults to `false`).

`CredentialWatchdog` is what stops that:

1. `Arbiter.Worker.fail_stopped/2` classifies a dying worker's stop reason. If
   it comes back `:auth_expired`, it calls
   `Arbiter.Agents.CredentialWatchdog.mark_expired/2` immediately — no waiting
   on a periodic probe.
2. Every subsequent dispatch or resume for that adapter reads
   `CredentialWatchdog.expired?/1` before spawning anything. A known-expired
   adapter is refused instantly, before the task transitions, before a
   worktree is provisioned, before a worker registers.
3. The refusal escalates to the coordinator (once — behind
   `Arbiter.CircuitBreaker`, not once per retry) with a re-authenticate
   remediation.

None of this requires a live probe. It is pure state: a map of adapter →
`:ok | {:expired, reason}`, held in the `CredentialWatchdog` GenServer and
served for free to every dispatch.

## The periodic probe is now optional, and "off" is a supported posture

`CredentialWatchdog` still *can* run its own periodic CLI probe
(`:adapters`, runtime-settable via `Arbiter.Settings`) to catch expiry that no
worker ever surfaced organically, and to auto-recover an adapter once
credentials are restored. That's a separate, much lower-frequency cost center
than the old per-dispatch probe — and it's fully independent of the
dispatch guard above, which works off held state regardless of whether
anything is probing to refresh it.

Setting `:adapters` to `[]` (the operator already did this for `gemini`,
cutting it from ~180 probes/day to 26) is a **supported, intentional
posture**, not an accident to route around:

- `expired?/1`, `mark_expired/2`, `mark_recovered/2` and the dispatch guard
  all keep working exactly as before — they're state operations, not probe
  operations.
- Nothing will *clear* an expiry mark on its own once nothing probes that
  adapter. Recovery then comes from an independent success signal instead —
  `Arbiter.Quota.CloudProbe`'s consecutive-401 tracking calls
  `mark_recovered/2` on a successful `/api/oauth/usage` poll for Claude — or
  an operator running `CredentialWatchdog.reset/1`.
- `quota_get.credentials_expired` (`Arbiter.Quota.serialize/1`) reflects the
  same held state either way, so the dashboard's expiry signal doesn't
  depend on probing being on.

See `Arbiter.Agents.CredentialWatchdog`'s moduledoc for the exact
configuration resolution order and the adapter-list semantics.

## Out of scope here

Two follow-ups were filed instead of folded in:

- Free (non-billed) expiry signals for codex/agy, so those adapters get the
  same organic detection Claude gets from the usage-poll 401 tracking.
- Whether an auth-shaped pre-flight hold (mirroring the existing
  `:quota_exhausted` hold in `Arbiter.Worker.PreflightHold`) is worth
  reintroducing now that pre-flight itself is gone.

A quota-exhausted live-probe signal (the other thing the old pre-flight probe
used to produce, consumed by `Arbiter.Worker.PreflightHold`,
`Arbiter.Board.Autopilot`'s retry hold and `Arbiter.Workflows.DispatchQueue`'s
held-intent backoff) no longer arrives from pre-flight either, for the same
reason: producing it required the same live probe this change removes. Those
call sites are unchanged and harmless — `PreflightHold.retry_not_before/3`
simply never receives a `:quota_exhausted` shape from this path anymore — but
a quota-exhausted dispatch will now be discovered the same way an auth
failure is: by the provider's own rejection once dispatched, not pre-guessed.
