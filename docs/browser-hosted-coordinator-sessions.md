# Browser-hosted coordinator sessions — design spec

**Status:** design proposal (deliverable for #1581; not yet approved)
**Date:** 2026-09-13
**Task:** bd-cyxzvq · **Tracker:** github:1581
**Author:** worker
**Builds on:** the usage ledger's session attribution (`apps/arbiter/lib/arbiter/usage/event.ex`,
bd-adyhvn / #1596), the session-JSONL archive (`docs/session-archive.md`, bd-db0p38),
per-agent config isolation (`Arbiter.Agents.Claude.ConfigDir`, bd-bw3466) and the
MCP scope tiers (`docs/mcp-server-design.md`, bd-b2eqn5).

> **Amendments folded in.** This spec is written against the four amendments on
> bd-cyxzvq, not the original ticket text. In particular the metering proxy the
> ticket was built on **no longer exists** (removed in #1605) — §2 and §7 replace
> it — and the memory/continuity question the ticket left open has since been
> **decided** by the operator; §9.4 designs to that decision rather than
> re-opening it.

## TL;DR

Run each coordinator session as **`tmux` inside its own transient systemd user
unit**, spawned by Arbiter via `systemd-run --user --scope`, and attach the
browser to it through a Phoenix Channel carrying raw ANSI. Meter it by
**ingesting the session's own Claude Code JSONL** — no proxy — into the existing
`Usage.Event` ledger under `source: :coordinator_session`.

Three empirical results drive the design (§4.2, §8.2, §7.2 for full commands and
observations):

1. **Restart survival is a cgroup problem, not a process-parentage problem.**
   `arbiter.service` sets no `KillMode`, so systemd's default `control-group`
   applies and kills *everything in the unit's cgroup* on restart — double-forking
   does not escape it. Measured: a tmux server spawned as a plain child of a
   stand-in service **died** on `systemctl --user restart`; an identical one
   placed in its own transient scope **survived**, and replayed **ticks 1..58
   with zero gaps** across the restart instant with no client ever attached.

2. **Proxy-free metering works in mode B with Remote Control active** — the
   blocking critical-path question from Amendment 2/4, and the answer is
   **positive**. In the operator's own bridged session, `totalCostUSD` climbed
   **$9.78 → $325.78 entirely inside the bridged window**, alongside 4,216
   `usage`-bearing records. Turns driven from claude.ai still land their tokens
   and dollars in the local JSONL. **No blocking finding to report.**

3. **`--remote-control` under an OAuth token fails *silently*, which is worse
   than the reported refusal.** It does not error. It starts a completely normal
   interactive session, runs turns fine, and just never establishes the bridge —
   zero `bridge-session` records, no `bridge*` keys, no `oauthAccount`. An
   operator would believe they had an AFK-reachable session and would not. Arbiter
   must **verify the bridge**, not trust the flag (§8.3).

The headline number for §1: that single measured session cost **$325.78** and
appears in `arb usage` as **$0.00**.

## 1. Motivation — the coordinator is the largest unmetered line item

`arb usage` reports dispatched workers. The coordinator session that *dispatches*
them is invisible. Every quota figure the operator produced on 2026-09-11/12 had
to carry the caveat "worker ledger only — the coordinator session and interactive
use also consume quota but are not in the ledger".

That gap is now quantified rather than asserted. Reading the operator's own
session JSONL (§7.2):

| | |
|---|---|
| one interactive coordinator session | **$325.78** |
| its `usage`-bearing assistant records | 4,216 |
| its size on disk | 25 MB / 14,550 lines |
| what `arb usage` shows for it | **$0.00** |

The operator's 2026-09-12 analysis put coordinator/interactive use at roughly **a
quarter of total consumption**. A cost report that omits a quarter of spend is not
a rounding error; it is the wrong answer, and it is wrong in the direction that
makes the fleet look cheaper than it is.

Two further motivations, both from the ticket: hosting the session lets Arbiter
**inject the context a coordinator needs** (workspace state, task queues, memory
layers) instead of relying on the operator to paste it, and it makes the session a
**first-class object** — startable, nameable, reattachable, auditable — rather
than a terminal window that exists only as long as a laptop stays awake.

### 1.1 Why the ledger is already half-built

This is the part the original ticket could not know. #1596 landed the attribution
schema **before** this RFC was written:

- `Usage.Event.task_id` is nullable.
- `@sources` already contains `:coordinator_session` and `:terminal_session`
  (`apps/arbiter/lib/arbiter/usage/event.ex:66`).
- `session_id` already exists as an attribute (`:210`).
- `arb usage` already accepts `--by source` and `--source coordinator_session`.

So the ledger is waiting for rows that nothing currently writes. The metering work
in §7 is **a producer**, not a schema redesign. `event.ex:45` even names this
ticket as the intended writer.

## 2. What changed under this RFC while it was queued

The ticket was filed 2026-09-12 05:21Z against an architecture that has since been
dismantled. Recording this explicitly because the original research tasks point at
modules that are gone:

| Change | Effect on this design |
|---|---|
| **#1605** deleted the Anthropic pass-through proxy — controller, route, `worker_base_url/1`, and `ANTHROPIC_BASE_URL` from the spawn env | The ticket's "point `ANTHROPIC_BASE_URL` at the proxy" path **does not exist**. §7 is proxy-free. |
| **#1602** deleted `RefreshProbe`; quota is now polled from `/api/oauth/usage` by `CloudProbe` | Gives account-level utilisation **percentages**, not per-request tokens. Cannot meter a session. |
| **#1596** made `task_id` nullable and added `source` + `session_id` | The attribution half is **done**. Extend it (§7.4). |
| **bd-db0p38** archives session JSONLs before Claude Code prunes them at ~21 days | The metering *and* transcript substrate already exists (§11). |

Reintroducing a proxy purely for sessions would re-add a component that was
deliberately removed, to obtain data that is already on disk. §7.3 evaluates it
anyway and rejects it on those grounds.

## 3. Architecture

```
  browser (xterm.js)                    BEAM — arbiter.service
 ┌──────────────────────┐             ┌──────────────────────────────────┐
 │ SessionLive          │  Phoenix    │ SessionRegistry  (Registry)      │
 │  ├ xterm + canvas    │◄─ Channel ─►│ SessionAttach    (GenServer/sess)│
 │  └ cost HUD          │  /socket    │  ├ tmux control ops (exec)       │
 └──────────────────────┘   ws        │  ├ pipe-pane reader (raw bytes)  │
                                      │  └ JSONL tailer ──► Usage.Event  │
                                      └────────────┬─────────────────────┘
                                                   │ systemd-run --user --scope
                                                   │ (ONE-WAY: creates a sibling)
   ══════════ restart boundary ═════════════════════════════════════════════
                                                   ▼
                        ┌────────────────────────────────────────────┐
                        │ arb-session-<id>.scope   (own cgroup)      │
                        │  └ tmux server (socket: run/session-<id>)  │
                        │      └ claude  (PTY, cwd = session root)   │
                        │           writes  <cfgdir>/projects/…jsonl │
                        └────────────────────────────────────────────┘
                             ▲                          ▲
                             │ tmux attach (fallback)   │ --remote-control
                          operator CLI                claude.ai (AFK)
```

The load-bearing property is the **restart boundary**: everything below it lives
in a cgroup that is a *sibling* of `arbiter.service`, so `systemctl --user restart
arbiter` cannot reach it. Arbiter holds no handle to the PTY that matters — on
reboot it re-discovers sessions by listing scope units and tmux sockets.

## 4. The PTY harness (research task 1)

### 4.1 The real constraint

The instinct is "a PTY owned by the supervision tree dies with the BEAM, so
double-fork it away". That instinct is **wrong on this host**, and the spike was
worth running precisely because it disproves the obvious answer.

`arbiter.service` is `Type=exec` and sets **no `KillMode`**, so the systemd default
`KillMode=control-group` applies. On restart systemd signals *every process in the
unit's cgroup*. Reparenting to PID 1 does not move a process out of a cgroup —
cgroup membership is inherited across `fork()` and preserved across `setsid()`.
So `setsid`, daemonising, and "tmux double-forks anyway" **all still die**.

Survival requires the PTY to be in a **different cgroup**, which on a systemd user
session means: in its own unit.

### 4.2 Spike — commands run and what was observed

Run 2026-09-13 against a throwaway transient unit standing in for
`arbiter.service` (same user manager, same default `KillMode`, no blast radius on
the live coordinator). Predictions were recorded before running.

**Setup** — one stand-in service spawning two PTYs, one each way:

```sh
# inside the stand-in service's ExecStart:
tmux -S $SOCK_A new-session -d -s coord "$WORKLOAD"                 # plain child
systemd-run --user --scope --quiet --unit=$TAG-ptyB \
  tmux -S $SOCK_B new-session -d -s coord "$WORKLOAD"               # escaped
```

The workload prints a numbered tick every 0.5 s, so output can be checked for gaps.

**Observed — cgroup placement (the mechanism):**

```
tmux[A] pid=1670957 cgroup=…/app.slice/arbspike1581-host.service
tmux[B] pid=1670971 cgroup=…/app.slice/arbspike1581-ptyB.scope
```

**Observed — a real restart cycle:**

```
$ systemctl --user restart arbspike1581-host.service     # rc=0, returned in 23ms
host MainPID before=1670952 after=1671655                # service genuinely restarted
tmux[A] pid=1670957  DEAD
tmux[B] pid=1670971  ALIVE  (cmd: /usr/bin/tmux -S …/tmuxB.sock new-se…)
scope state: active
```

**Observed — detached output replay.** No client was ever attached
(`attached_clients=0`). After the restart:

```
$ tmux -S $SOCK_B capture-pane -p -S - -t coord
tick 1 04:37:06.541 … tick 58 04:37:35.189
range 1..58, count 58        # gap check: no missing tick numbers
```

Tick 26 landed at 04:37:19.105 — **7 ms after `systemctl restart` returned**. The
program neither blocked nor lost output while unattended; tmux buffered it into
pane history. Default `history-limit` is **30000 lines**.

**Observed — the mechanisms the transport needs:**

```
$ tmux -S $SOCK_B resize-window -t coord -x 120 -y 40
after resize: 120x40                       # resize reaches a detached session
$ tmux -S $SOCK_B capture-pane -p -e -S -3 -t coord
                                           # -e preserves ANSI for replay into xterm.js
$ tmux -S $SOCK_B pipe-pane -t coord -O "cat >> transcript.raw"
bytes captured in 2s: 88                   # live raw byte stream, transcript + tail
```

**Observed — a literal attach / detach / restart / reattach cycle.** The capture
above proves survival; this proves the session is still a usable terminal
afterwards, with a real tmux client attaching (run from an outer tmux pane, so
the client has a genuine TTY):

```sh
tmux -S $SOCK attach -t coord      # attached_clients: 0 -> 1, client renders live ticks
tmux -S $SOCK detach-client -s coord                      # 1 -> 0
systemctl --user restart <stand-in-arbiter>               # PTY pid SURVIVED
tmux -S $SOCK attach -t coord      # 0 -> 1, client renders live ticks 32,33,34
```

Continuity across the whole cycle: `ticks 1..34, count 34` — no gaps introduced by
attaching, detaching, restarting, or reattaching.

**Observed — arbiter never returning:**

```
$ systemctl --user stop arbspike1581-host.service
host: inactive   scope: active
tmux still serving: coord: 1 windows
```

The session outlives arbiter indefinitely. See §4.6.

Teardown was by exact unit and socket name (`systemctl --user stop <unit>`,
`tmux -S <sock> kill-server`); `systemctl --user is-active arbiter.service`
confirmed `active` afterwards.

**This whole section is now an automated test.** Phase 2 (bd-b95w36) turned
these observations into
`apps/arbiter/test/integration/session_restart_survival_test.exs`, negative
control included — see §4.9.

### 4.3 Recommendation — transient systemd user unit, tmux inside it

```sh
systemd-run --user --scope --unit=arb-session-<id> --collect \
  tmux -S $XDG_RUNTIME_DIR/arbiter/session-<id>.sock \
       new-session -d -s coord -x 200 -y 50 \
       -e CLAUDE_CONFIG_DIR=… -e ARB_SESSION_ID=… \
       "claude <launch-flags>"
```

Why this pair, rather than either alone:

- **systemd gives the lifetime.** The scope is a sibling cgroup, which is the only
  thing that actually survives a restart (§4.1). It also gives us naming
  (`arb-session-<id>`), enumeration (`systemctl --user list-units 'arb-session-*'`)
  and resource limits for free.
- **tmux gives the PTY, the scrollback and the second door.** It is a real PTY
  master with SIGWINCH handling, 30k lines of replay buffer, `pipe-pane` for a
  live byte stream, and — decisively for AC 6 — a **CLI attach path that does not
  involve Arbiter at all** (§4.7).

tmux 3.7c is already installed on this host; `dtach`, `abduco` and `screen` are
not, and `script` is not either. Adding a dependency that is already present beats
adding one that is not.

Arbiter holds **no** long-lived handle to the PTY. It shells out for control
operations and keeps one reader per attached browser. This is the property that
makes restart survival true by construction rather than by careful coding: there
is no supervision link to sever.

### 4.4 Rejected alternatives

| Alternative | Why it loses |
|---|---|
| **In-BEAM PTY (`:erlexec`, `expty`)** | Fatal on the hard requirement. The PTY master is a BEAM-owned fd; when the BEAM exits the master closes, the slave gets `SIGHUP`, and the session dies. A coordinator that restarts arbiter would kill itself mid-restart — the exact scenario decision 1 forbids, and one that has occurred twice in one day in practice. `:erlexec`'s OS-level middleman does not help: it is spawned by the BEAM, lives in `arbiter.service`'s cgroup, and §4.2 shows that cgroup is cleared on restart. Also: neither is in `mix.lock`, both add a NIF/port-driver dependency, and `expty` would put a C NIF in the path of the operator's primary interface. |
| **Detachable multiplexer that is *not* in its own unit** (`tmux`/`dtach`/`abduco` spawned as a plain child) | This is variant A, and it was **measured dead** (§4.2). It is the intuitive answer and it is wrong. Worth stating loudly because "tmux detaches, so it survives" is exactly the reasoning a reviewer would accept without testing. `dtach`/`abduco` additionally are not installed. |
| **A separate long-lived daemon** (one `arbiter-ptyd` unit hosting all sessions) | Survives restarts, but re-creates every problem tmux already solved — PTY allocation, scrollback ring, resize, multi-client attach, a wire protocol — as new code on the critical path of the operator's primary interface. It also makes the blast radius *worse*: one daemon crash takes down every session, whereas one scope per session is independently faulty. Its only real advantage (a stable supervision point) is obtainable by enumerating scope units. |
| **A per-session `.service` file written to `~/.config/systemd/user/`** | Works, and is close to the recommendation, but persists state on disk that must be garbage-collected, requires `daemon-reload` per session, and survives reboot in a way that resurrects dead sessions. `--scope` is transient: it exists exactly as long as the processes in it. |
| **`setsid` / double-fork reparenting** | **Does not work here.** Reparenting to PID 1 does not change cgroup membership; systemd kills by cgroup. Measured: variant A's tmux server *had* already double-forked (tmux daemonises its server) and died anyway. |

### 4.5 Output produced while detached

Answered empirically in §4.2: tmux writes into the pane's history ring whether or
not a client is attached, and the process never blocks. On reattach:

1. **Replay** — `capture-pane -p -e -S -<N>` returns the last N lines with ANSI
   intact; the channel ships it as one `snapshot` frame that xterm.js writes
   verbatim before live bytes resume.
2. **Live** — `pipe-pane -O` streams raw bytes from that point on.

The seam between the two is the one place ordering can go wrong. Open `pipe-pane`
**first**, then take the snapshot, then drop any streamed bytes that precede the
snapshot's end marker — overlap is cheap to discard, a gap is not recoverable.

Bound: 30,000 lines per pane by default. For a coordinator session that is
generous (it is a scrollback ring, not the transcript — §11 persists the full
byte stream separately), but §12 flags raising it as a tuning question.

### 4.6 Orphan reaping

The spike refined the prediction here in a way that matters. The transient scope
**self-reaps when its payload exits** — no `RemainAfterExit` needed. But when
arbiter was *stopped entirely*, the scope stayed `active` and tmux kept serving
indefinitely. So systemd garbage-collects the *unit*, never the *session*.

The orphan is therefore a live agent process with nobody watching it, which is
also the expensive failure: an idle `claude` costs nothing, but one in a tool loop
bills against quota with no HUD showing it.

Proposed reaping, in order of preference:

1. **Adoption sweep on boot.** Arbiter enumerates `arb-session-*` scopes at
   startup, matches them against its `sessions` table, and re-adopts. Anything
   with no matching row is an orphan from a previous era → kill. This is also how
   reattach works after a restart, so it is not extra machinery.
2. **Idle deadline.** Each session records `last_client_at` and `last_turn_at`.
   A sweep terminates sessions idle beyond a configured TTL (suggest 24 h), with
   the operator able to pin a session as `keep_alive`.
3. **A dead-man's switch inside the scope.** The scope's payload is a wrapper that
   polls for arbiter's liveness and exits after a grace window (suggest 1 h) with
   no arbiter *and* no attached client. This is the only mechanism that works if
   arbiter never comes back at all, which is the case §4.2 measured.

(3) is the honest answer to "what if arbiter never returns" and should not be
skipped just because (1) covers the common case.

### 4.7 Fallback path when the web app is down (AC 6)

Because the browser is intended to **replace** the terminal, the failure mode
"dashboard down, session unreachable" is unacceptable. It is also trivially
avoided by the recommendation, and this is a large part of why tmux wins:

```sh
# list live sessions without Arbiter running at all
systemctl --user list-units 'arb-session-*' --no-legend

# attach directly, full interactivity, no Phoenix in the path
tmux -S $XDG_RUNTIME_DIR/arbiter/session-<id>.sock attach -t coord

# read-only look
tmux -S …/session-<id>.sock attach -r -t coord
```

Nothing in this path touches the BEAM, the database, or the network. Ship it as
`arb session attach <id>` (a thin `exec` wrapper) so the operator does not have to
remember socket paths, and **document the raw `tmux -S … attach` form too** —
`arb` is an escript that talks to the Phoenix API, so it may itself be unavailable
in precisely the scenario this path exists for.

Third door, for when the operator is off the LAN entirely: Remote Control (§8).

### 4.8 Status — phase 1 shipped (bd-bpt0ag, #1682)

The session lifecycle core is implemented and the §4.1 mechanism is now
measured from inside `arbiter.service` itself, not just from a stand-in:

```
spawner (BEAM)   …/user@1000.service/app.slice/arbiter.service
tmux (pid …)     …/user@1000.service/app.slice/arb-session-<uuid>.scope
```

A **sibling** under `app.slice`, exactly as §4.1 predicts. That reading is
produced by `apps/arbiter/test/integration/session_scope_test.exs`, which is
tagged `:live_systemd` and excluded from the default suite — run it with
`mix test --include live_systemd`.

What shipped:

  * `sessions` table + `Arbiter.Sessions.Session`, field-for-field with §7.4
    item 4. `usage_events.session_id` joins to `provider_session_id` by string,
    so the rows phase 6's ingest has been writing since bd-be804c attach to a
    session row as soon as one exists.
  * `Arbiter.Sessions.launch/1` running §4.3's command shape verbatim, plus
    `list/0`, `get/1`, `kill/2`. Control operations shell out through
    `Arbiter.Sessions.Runner` (a behaviour, so tests drive a scripted
    `systemctl`/`tmux`) and its one real implementation goes through
    `ReleaseEnv.cmd/3`, so the release-env scrub happens once at the scope
    boundary and is inherited by the tmux server and every pane.
  * `Arbiter.Sessions.Adoption.sweep/1` as a primary-gated boot task — §4.6
    item 1. Phase 1 deliberately stops short of §4.6's "no matching row →
    kill": an unrecognised live scope is reported in `:orphans` and logged,
    never stopped, because the sweep's model of the host is by definition
    already wrong in that case. Reaping stays phase 10.
  * §10.1's self-kill refusal, enforced in `kill/2`, and the restart
    rate-limit decision as a pure predicate (`Arbiter.Sessions.Guards`)
    waiting for whichever phase adds the restart endpoint.
  * `Arbiter.Sessions.Provider` keeps the payload provider-agnostic. Its
    Claude Code adapter launches a **shell** for now: §9.2's three interactive
    gates mean an unprovisioned `claude` would hang forever in a detached
    pane. Phase 3 swaps the payload, nothing else.

Not done here, and not attempted: transport, UI, provisioning, Remote
Control, and the §4.6 idle deadline / dead-man's switch.

### 4.9 Status — phase 2 shipped: §4.2 is a regression test (bd-b95w36)

§4.8 measures the *mechanism* (sibling cgroup). It cannot measure the
*consequence*, because it launches from the ExUnit BEAM's own cgroup and
nothing ever restarts that. Phase 2 closes that gap:
`apps/arbiter/test/integration/session_restart_survival_test.exs` brings up a
throwaway systemd **user service** standing in for `arbiter.service` — same
user manager, same `KillMode` (both set it by omission, so the default
`control-group` applies; the test reads `arbiter.service`'s own value back and
asserts they match), no blast radius on the live coordinator — launches a
session from inside it through the real `Arbiter.Sessions.launch/1`, and
restarts it for real.

The launch gets *inside* the unit through the phase-1 seam: the unit's
`ExecStart` is a small POSIX `sh` agent watching a command spool, and
`Arbiter.Test.StandinUnit` implements `Arbiter.Sessions.Runner` by writing
into that spool. The argv, the env and the ordering are the production code
path; only the process that executes the argv moves into the restartable
cgroup.

Measured on the arbiter host, 2026-09-15:

```
[bd-b95w36] cgroup placement before the restart:
  stand-in unit      arbrs1413-host.service (MainPID 3037301)
  tmux, escaped      pid 3037377  …/app.slice/arb-session-e4139553-….scope
  tmux, plain child  pid 3037307  …/app.slice/arbrs1413-host.service

[bd-b95w36] restart survival, measured:
  arbrs1413-host.service MainPID  3037301 -> 3037476
  arb-session-e4139553-….scope  active
  tmux, escaped      pid 3037377  ALIVE
  tmux, plain child  pid 3037307  DEAD
  pane ticks         range 1..20, count 20 (restart crossed at 10)

[bd-b95w36] host: inactive   scope: active
```

Four assertions, one per §4.2 observation: the scope is still `active`; the
tmux server is the **same pid**, so it survived rather than restarted; the
pane's sequenced output is contiguous `1..N` across the restart instant (the
spike's "range 1..58, count 58"); and — the negative control — a tmux started
as a *plain child* of the same unit is dead, which is what proves the test is
capable of failing. Verified by mutation: rewriting the runner to launch the
session as a plain child fails both tests, at the cgroup assertion and again
at `scope is inactive after restarting`.

**It is opt-in, and its absence is loud.** GitHub Actions runners generally
have no systemd user instance, so the test is tagged `:systemd_user` and
excluded from `mix precommit`. A restart-survival test that quietly does not
run is worse than none, so `test/test_helper.exs` prints a banner naming the
reason on every run that does not include it, and on a host with no user
manager the module tags itself `skip: <reason>` — ExUnit reports *skipped*,
not passed. Run it with:

```sh
scripts/session-restart-survival.sh          # --log FILE to capture output
```

which checks the preconditions, runs the test from `apps/arbiter` (an umbrella
`mix test <path>` at the root is not scoped to one app), and re-checks
`arbiter.service`'s state afterwards.

## 5. Transport and protocol (research task 2)

### 5.1 Channel, not LiveView hook-only

A **Phoenix Channel** on a dedicated socket, with the LiveView page rendering
chrome (HUD, controls) and a colocated hook owning the terminal element.

LiveView's diffing is the wrong tool for a 60 fps ANSI byte stream: every frame
would become a diff against an element the hook is mutating anyway (which is why
it must carry `phx-update="ignore"`). A Channel gives a raw binary path, its own
backpressure, and — importantly — a topic keyed to the session id rather than to a
LiveView process, so a browser reload reattaches to the same session without
re-mounting terminal state.

`arbiter_web` has **no user socket today** (only `/live` and live-reload), so this
is new but small: one `socket "/session"` entry in `endpoint.ex` plus one channel
module.

### 5.2 Message envelope

Deliberately provider-neutral: nothing below mentions Claude. A terminal is bytes,
a size, and a lifecycle.

**Client → server**

| Event | Payload | Notes |
|---|---|---|
| `join` | `%{session_id, last_seq \| nil, cols, rows}` | `last_seq` requests resume; `nil` requests full snapshot |
| `stdin` | `{:binary, bytes}` | raw bytes, never JSON-wrapped — no UTF-8 mangling of partial sequences |
| `resize` | `%{cols, rows}` | debounced client-side (~100 ms) |
| `detach` | `%{}` | leave the session running; server drops the reader |
| `kill` | `%{confirm: true}` | terminate the agent; scope self-reaps |
| `ping` | `%{ts}` | liveness/RTT for the HUD |

**Server → client**

| Event | Payload | Notes |
|---|---|---|
| `snapshot` | `%{seq, data}` | ANSI-preserving scrollback replay on (re)attach |
| `stdout` | `{:binary, bytes}` with `seq` in metadata | live PTY output |
| `exit` | `%{code, reason}` | agent exited; session row closes |
| `meta` | `%{cols, rows, attached_clients, title}` | reconciles a resize done by another client |
| `usage` | `%{tokens_in, tokens_out, cache_creation, cache_read, cost_usd, model}` | HUD feed (§7.5) |
| `error` | `%{code, detail}` | e.g. `:session_gone`, `:bridge_unavailable` |

`stdin`/`stdout` are **binary frames**. Everything else is JSON. A terminal stream
splits multi-byte UTF-8 and escape sequences across reads; decoding at the
transport corrupts them. Decode only in xterm.js, which reassembles by design.

### 5.3 Sequence numbers, resume, and backpressure

Every `stdout` frame carries a monotonic `seq` per session. The server keeps a
bounded ring (suggest 2 MB) of recent frames.

- **Reconnect within the ring** → client sends `last_seq`, server replays
  `last_seq+1..current`. Seamless; no repaint.
- **Reconnect outside the ring** (or first join) → server sends `snapshot` from
  `capture-pane` and resets the client's sequence. Cheap and always correct.

This is why resume is keyed to **session id + seq**, not to a socket: a flaky
connection, a laptop sleeping, and an arbiter restart are all the same event to
the client.

**Backpressure.** A browser on a slow link cannot keep up with a build log. Phoenix
channels buffer per-socket, so the naive version grows the BEAM's heap until
something dies. Instead:

1. The reader reads `pipe-pane` output in chunks and **coalesces** — if more bytes
   arrive while a push is in flight, concatenate rather than enqueue.
2. Above a high-water mark (suggest 256 KB pending), **drop to snapshot mode**:
   discard the backlog, push one `capture-pane` snapshot, resume live. A terminal's
   value is its *current* contents; showing the user the present instantly beats
   replaying a backlog they will scroll past. The full byte stream is preserved in
   the transcript regardless (§11), so nothing is actually lost.
3. `stdin` needs no backpressure — human typing is orders of magnitude slower than
   any PTY.

### 5.4 Staying provider-agnostic (decision 7)

The envelope above contains no provider concept, and this is the whole trick:
**a PTY session is provider-agnostic by construction** because a terminal is bytes.
Provider differences live entirely in two places outside the transport:

1. **Launch spec** — argv, env, config dir, per-provider flags. A behaviour
   (`Arbiter.Sessions.Provider`) with `launch_spec/1`, mirroring how
   `Arbiter.MCP.AgentConfig` already fans out to per-agent writers.
2. **Usage ingestion** — each CLI records usage differently. `agy`/gemini and
   codex have their own on-disk formats (`docs/session-archive.md` notes both
   exist and, unlike Claude Code, are not pruned). The behaviour gains
   `usage_source/1`; §7.6 covers the shape.

`Arbiter.Usage.ClaudeSessionFile`'s moduledoc already states the precedent —
"deliberately Claude-Code-specific — no multi-provider `Provider` behaviour until
a second provider actually needs one (bd-au3xrq)". This RFC does **not** propose
building the behaviour now. It proposes not putting provider knowledge in the
envelope, so that adding one later is additive.

### 5.5 Status — phase 4 shipped (bd-3ymdvi, #1685)

The transport is implemented. Six things in §5 were under-specified or wrong
and were decided while building it; they are recorded here rather than left
for the next reader to rediscover.

**1. `seq` is framed into the payload, because there is no metadata.**
§5.2 describes `stdout` as "`{:binary, bytes}` with `seq` in metadata". A
Phoenix binary push is `{:binary, iodata}` and the WebSocket frame carries the
payload and nothing else — no event name, no ref, no headers. Since §5.3's
resume is keyed on session id + seq, the number has to be in the bytes:

```
<<"ARB1", seq::unsigned-big-64, payload::binary>>
```

`Arbiter.Sessions.Frame` prefixes and strips; it never looks at the payload,
which is what keeps a split `\e[1;31m` or a split `🚀` byte-exact. Both
directions use it — a client's stdin seq is what lets the server drop stdin
a reconnecting client re-sent, rather than typing it into the pane twice.

**2. One reader per session, not per attached client.** §4.3 says "one reader
per attached browser". tmux makes that impossible: `pipe-pane` is a property
of the pane, singular — issuing it twice replaces the first pipe. It is also
the wrong shape for §5.3, which wants one `seq` space and one ring *per
session* so two clients resuming from different points are talking about the
same numbers. The property §4.3 actually cares about is untouched: a detach or
an `arbiter` restart drops the reader, never the session.

**3. `seq` is a byte offset into the pipe file, not a counter.** This falls
out of `pipe-pane -O 'cat >> <path>'` and is the most useful invariant in the
phase. Resume arithmetic becomes `pread(file, last_seq, head - last_seq)`; the
in-memory ring becomes a fast path that preserves frame boundaries rather than
the source of truth; and a reconnect after an `arbiter` restart is **gapless**
rather than a repaint, because the `cat` tmux spawned lives in the *session's*
scope, keeps appending while arbiter is dead, and a new reader picks the
numbering back up from the file size. §12 item 7's ring size therefore matters
less than it looked: outside the ring is not automatically a repaint.

**4. Resize: last writer wins** (§12 item 8, which suggested "first client
owns size, others letterbox"). The most recent `resize` from any attached
client sets the pane size and every client is sent `meta`. This matches tmux's
own `window-size latest`, needs no size-ownership handover when the owning
client leaves, and is compatible with the suggestion — letterboxing is a
frontend response to `meta`, which phase 5 can add without the transport
having an opinion.

**5. The client must reconnect on a *clean* close — phase 5 needs this line.**
`phoenix.js` deliberately does not reconnect after WebSocket close code `1000`
(normal closure), and a graceful `systemctl --user restart arbiter` produces
exactly that: Bandit closes every socket with 1000 on shutdown before the BEAM
exits. For a terminal client that is the wrong reading. The session *outlives*
the server by design (§4.3), so a clean server close means "back shortly", not
"stop watching this terminal" — without an override, the tab goes dead on
every deploy and decision 3's gapless resume never gets a chance to run. One
line in the socket's `onClose` fixes it:

```js
if (code === 1000) socket.reconnectTimer.scheduleTimeout()
```

This was found, not reasoned about: the first run of
`ArbiterWeb.SessionTransportSocketTest` hung at "socket closed at seq 19 (code
1000)" and never rejoined. Phase 5's hook must carry the same line, and its
rejoin params must be a **closure** — `phoenix.js` only re-evaluates join
params that are a function, so an object literal silently resumes from the
`last_seq` the tab first connected with rather than the newest one.

**6. A joining client is guaranteed its `snapshot` before any live frame.**
§5.2 lists the events but says nothing about their order at join, and the
obvious implementation gets it wrong: the reader registers the new subscriber
*inside* the attach call, so its next poll can deliver a live frame to the
channel before the channel has queued its own post-join flush. The client then
sees a frame at `seq` newer than the snapshot, followed by the snapshot — and
repaints backwards over bytes it has already drawn. The channel therefore
holds anything that arrives in that window and drains it, in order, right
after the snapshot or replay. Phase 5's client may rely on this: after a
successful `join`, the first thing on the wire is always `snapshot` or the
replay frames.

Backpressure is §5.3 item 2 as written: each client acknowledges the bytes it
has pushed onto the wire, a client past the high-water mark stops receiving
frames and keeps no backlog, and one `capture-pane` snapshot repaints it when
its acknowledgements catch up.

One limit of that, so phase 5 does not assume more than is there: the
acknowledgement is sent the moment a frame is handed to `push/3`, which returns
as soon as the message reaches the transport process. The high-water mark
therefore bounds the **channel process's** mailbox, not the Bandit connection
process's send queue, which is where a genuinely slow *network* client's bytes
would pile up. That is the right first cut — it is the queue the reader can see
and the one AC 4 asks about — but a socket-level bound is still unbuilt.

Tested headlessly: `Arbiter.Sessions.StreamTest` and
`ArbiterWeb.SessionChannelTest` run against a scripted PTY that appends to the
same kind of file tmux writes, so the byte path under test is the real one.
`Arbiter.Integration.SessionTmuxTest` runs the same operations against a real
tmux server on a scratch socket — cheap enough for the default suite, skipped
only where tmux is absent.

Tested over a real socket, too. `ArbiterWeb.SessionTransportSocketTest` stands
the endpoint up on a real port under Bandit and drives it with
`scripts/verify_session_transport.mjs` — the same `phoenix.js` the dashboard
ships, run under Node's built-in `WebSocket` (no npm; §6.1). It stops the
listener *and* the reader, lets the pane keep writing to the pipe file while
both are down, brings them back, and asserts the client's own verdict:

```
joined (#1): {"mode":"snapshot","seq":0}
before-the-restart
socket closed at seq 19 (code 1000) — will resume
joined (#2): {"mode":"resumed","seq":37}
during-the-outage
RESULT: PASS — frames=3 bytes=55 seq=55 reconnects=1 gaps=0 duplicates=0
```

That script is also the instrument for AC 8 on the live host: point it at a
real session, `systemctl --user restart arbiter`, and read the same summary
line.

## 6. Frontend (research task 3)

### 6.1 The constraint nobody expects: there is no npm

`apps/arbiter_web/assets` has **no `package.json` and no `node_modules`**.
`config/config.exs:160` runs esbuild directly over `js/app.js`, and third-party JS
is **vendored** as source (`assets/vendor/topbar.js`, `daisyui.js`, …).

So "add `@xterm/xterm`" is not `npm i`. Options:

- **Vendor the built ESM bundle** into `assets/vendor/xterm/` and import it
  relatively, exactly as `topbar` is imported (`import topbar from
  "../vendor/topbar"` — `app.js:26`). Consistent with the repo, no new toolchain,
  reviewable diff, pinned by construction. Downside: a ~300 KB vendored artifact
  in git and manual upgrades.
- **Introduce `package.json`** for this one dependency. Cleaner upgrades, but adds
  an npm install step to every build, CI and worker worktree — a real cost across
  a fleet that creates worktrees constantly.

**Recommendation: vendor it**, and record the upstream version in a header comment.
One dependency does not justify a package manager on every worktree. Revisit if a
second JS dependency appears. Note xterm also ships **CSS** (`xterm.css`) which
must be vendored into `assets/css/` and imported from `app.css`.

### 6.2 Renderer: canvas, not WebGL

**`@xterm/addon-canvas`.** Justification specific to this app:

- The WebGL addon is faster on large, fast-scrolling output, but it consumes a
  WebGL context. Browsers cap live contexts (~8–16); the Arbiter dashboard is a
  multi-panel app the operator keeps open across tabs, and decision 2 asks for
  **multiple concurrent sessions**. Several terminals plus any future chart is
  exactly the shape that hits context loss, which manifests as a blank terminal —
  an awful failure for the primary interface.
- WebGL needs explicit `onContextLoss` handling and a renderer rebuild. Canvas
  degrades gracefully and needs none.
- The workload is an interactive agent session — human-paced turns, not
  `yes` piped to a terminal. Canvas is comfortably sufficient.

Keep the DOM renderer as automatic fallback; xterm falls back on its own if canvas
construction fails.

### 6.3 Interaction details

- **Copy/paste.** Enable `macOptionIsMeta: false` and rely on xterm's default
  selection; bind `Ctrl/Cmd+Shift+C/V` via `attachCustomKeyEventHandler` so plain
  `Ctrl+C` still sends `SIGINT` to the agent — the single most common terminal
  papercut. Paste goes through `navigator.clipboard.readText()`; large pastes are
  chunked into `stdin` frames.
- **Narrow widths.** A terminal cannot reflow meaningfully below ~80 columns. Do
  not pretend: below the breakpoint, render the terminal in a horizontally
  scrollable container at a fixed 80 columns rather than shrinking the font to
  illegibility. Mobile is a *monitoring* surface — for real AFK work the answer is
  Remote Control (§8), which gives a purpose-built mobile UI for free. That is a
  design decision worth making explicitly rather than shipping a bad phone
  terminal.
- **Scrollback.** Set xterm `scrollback: 5000` client-side. The server holds 30k
  lines (§4.5) and the transcript holds everything (§11); the client only needs
  what the operator will actually scroll.
- **Cost HUD.** Pin it **outside** the xterm element — a slim bar above or beside
  it, in the LiveView, fed by the `usage` channel event. Overlaying it on the
  terminal would fight `FitAddon` for rows and shift reflow on every update. The
  HUD is LiveView-rendered (cheap, infrequent), the terminal is hook-owned
  (`phx-update="ignore"`); they never contend.
- **Fit.** `FitAddon` on a `ResizeObserver`, debounced, emitting `resize`.

The repo already has the colocated-hook precedent for terminal-ish UI:
`.LogStreamStick` in `core_components/domain.ex:578` does scroll-pinning for the
live worker log. The session hook is the same pattern, one level up.

## 7. Metering and attribution (research task 4)

### 7.1 Recommendation

**Ingest the session's own Claude Code JSONL.** Tail it live for the HUD; reconcile
at session end; write `Usage.Event` rows with `source: :coordinator_session` and
`session_id`.

### 7.2 Evidence, including the critical-path result (AC 10c)

Measured against the operator's real, already-existing bridged session —
a genuine mode B + `--remote-control` session, which is exactly the configuration
Amendment 2 flagged as critical path.

**The JSONL carries dollars, not just tokens.** A `cost-state` record
(token-free sample, real shape):

```json
{"type":"cost-state","sessionId":"…","totalCostUSD":9.777289,
 "totalAPIDuration":350343,"totalDuration":668525,"startTime":1788556943788,
 "modelUsage":{"claude-opus-5[1m]":{
    "inputTokens":1048,"outputTokens":24032,"thinkingTokens":10936,
    "cacheReadInputTokens":9410278,"cacheCreationInputTokens":446611,
    "webSearchRequests":0,"costUSD":9.777289}},
 "hasUnknownModelCost":false}
```

**Remote Control is visible in the same file** as `bridge-session` records:

```json
{"type":"bridge-session","sessionId":"…","bridgeSessionId":"cse_01Srk…",
 "lastSequenceNum":0,"ownerAccountUuid":"…","ownerOrganizationUuid":"…"}
```

**The critical-path measurement.** Within that one session:

| Measurement | Value |
|---|---|
| `bridge-session` records | **546**, one distinct `bridgeSessionId`, spanning lines 3 → 14543 |
| assistant records carrying `usage` **inside the bridged window** | **4,216** |
| `cost-state` records inside the bridged window | **16** |
| `totalCostUSD` across the bridged window | **$9.78 → $325.78** |

Interleaving confirms it turn-by-turn — `usage` records appear immediately before
and after each `bridge-session` record, continuously.

**Conclusion: proxy-free metering works in mode B with Remote Control active.**
Turns driven from claude.ai still record usage and cost locally, because the model
calls still originate from the local CLI process; the bridge only carries operator
input in and rendered output out. **No blocking finding.**

One corroborating detail: consecutive records repeat identical totals (e.g.
`424072` three times), the streaming re-emit duplication that
`ClaudeSessionFile`'s moduledoc documents and `read_totals/2` already dedupes by
`message.id`. Independent confirmation that the existing reader's central gotcha
is real and correctly handled.

### 7.3 Alternatives evaluated

| Option | Verdict |
|---|---|
| **JSONL ingestion** (recommended) | Works today, in both auth modes, with Remote Control, with **no launch-time configuration the session could omit**. Carries tokens *and* dollars *and* per-model breakdown. ~80% of the reader already exists. |
| **Reintroduce a proxy for sessions** | **Rejected.** #1605 removed it deliberately; re-adding it for data already on disk is a regression. It would also need `ANTHROPIC_BASE_URL` in the session env — a single misconfiguration silently unmeters a session, the exact failure this feature exists to fix. It is *more* fragile than the file, not less. Worth noting it also fails on a technicality: it cannot see cache-read/cache-write split pricing decisions the CLI makes, and would force us to re-derive cost the CLI already computed. |
| **Claude Code OpenTelemetry export** | **Rejected for now.** Claude Code can export OTel metrics, but it needs a collector endpoint configured at launch (same silent-misconfiguration risk as the proxy), adds an infrastructure dependency Arbiter does not otherwise have, and is aggregate-oriented. Reasonable *later* as a cross-provider unifier; not the first implementation. |
| **`CloudProbe` / `/api/oauth/usage`** | **Not viable.** Account-level utilisation percentages, not per-session tokens (#1602). It answers "how close to the cap", not "what did this session cost". Complementary, not a substitute. |
| **Parse the rendered terminal output** | **Rejected.** Scraping `/cost` output is brittle and only available on demand. |

### 7.4 Schema — extend #1596, do not re-propose it

The schema is already correct. Required changes are small:

1. **Write rows.** New `Arbiter.Sessions.UsageIngest` creates `Usage.Event` with
   `source: :coordinator_session`, `session_id: <arbiter session id>`,
   `task_id: nil`. No migration needed for the discriminator — `:66` already lists
   it.
2. **Cost.** `cost_usd` from `cost-state.totalCostUSD` (delta since last row).
   This **corrects a documented limitation**: `ClaudeSessionFile`'s moduledoc says
   the on-disk data carries "no per-turn dollar figure … so a reconciled row
   records deduped token counts with `cost_usd` left `nil`". That is true of
   `assistant` lines and **false of the file as a whole** — `cost-state` lines
   carry `totalCostUSD` and per-model `costUSD`. Extending the reader to parse
   `cost-state` therefore improves *worker* reconciliation too, not just sessions.
   Prompt-cache pricing needs no new arithmetic: the CLI has already applied the
   cache-write/cache-read price split, and the ledger already has
   `cache_creation_tokens`/`cache_read_tokens` (`:176`/`:180`) to record the
   buckets alongside it. **Reuse the CLI's number; do not recompute it.**
3. **One index.** `Usage.Event` indexes `[:source, :occurred_at]` (`:79`). Add
   `[:session_id]` for `--by session` to be cheap.
4. **A `sessions` table** (the new entity) — id, provider, workspace binding,
   scope unit, tmux socket, config dir, cwd, provider session id, auth mode,
   remote-control flag, `started_at`/`ended_at`, `last_client_at`. `Usage.Event`
   references it by the existing `session_id` string; no FK churn.

### 7.5 Live HUD and end-of-session reconciliation

**Live (cheap, approximate).** A tailer follows the JSONL with a file watcher,
parses appended lines, and pushes `usage` channel events. `cost-state` records are
periodic, so between them the HUD shows token deltas and the last known cost. Push
on a timer (~2 s) rather than per line — a busy turn appends dozens of records and
the HUD does not need 30 Hz.

**Authoritative (at session end, and periodically).** Re-read the file with
`read_totals/2` semantics — dedupe by `message.id`, honour `:since` — and write the
reconciled row. This is the same reconcile-from-disk pattern
`Arbiter.Usage.ClaudeSessionFile` already exists to perform for crashed workers;
sessions are just a longer-lived instance of the same problem.

Two wrinkles the reader already anticipates:
- **`:since` is load-bearing.** A resumed session appends to the same file, so
  every ingest must be windowed to avoid re-billing. `read_totals/2` takes
  `:since` for exactly this reason.
- **Rollover.** A long session hitting `--resume`/compaction may change session
  ids; `locate/2` globs by session id, so the session row must track the
  *current* provider session id, not just the launch one.

### 7.6 `arb usage` gains a session dimension

Already present from #1596: `--by source` and `--source coordinator_session`.
Missing, and the actual ask:

```
arb usage --by session [--since 7d]      # one row per session: cost, tokens, duration
arb usage --session <id>                 # the event detail view, scoped to one session
```

`--by session` must show *only* session-sourced rows (`task_id` is nil for them),
mirroring how `--by task` already "deliberately **excludes**" sessionful sources
"rather than inventing a phantom task id"
(`apps/arbiter_cli/lib/arbiter_cli/cmd/usage.ex:32`). Add `session` to the `--by`
list at `:13` and a `session` filter alongside `source:` at `:98`.

With that, the §1 table closes: the $325.78 session appears in `arb usage --by
session` and in the `--by day` totals it currently falsifies.

### 7.7 Status — phase 6 shipped (bd-be804c, #1651)

Items 1–3 of §7.4 and the "authoritative" half of §7.5 are implemented and
metering today's **CLI** coordinator, ahead of the session lifecycle, transport
and UI phases. What shipped:

  * `Arbiter.Usage.ClaudeSessionFile` parses `cost-state`, so `read_totals/2`
    now returns `cost_usd` / `model_costs` / `duration_ms` alongside the token
    buckets. Both worker reconciliation paths (`Arbiter.Worker`'s in-process
    fallback and `Arbiter.Workers.Reconciler`'s boot sweep) write a real dollar
    figure instead of `nil`.
  * `Arbiter.Sessions.UsageIngest` sweeps the directories named by
    `ARBITER_COORDINATOR_SESSION_DIRS` every 5 minutes and writes
    `source: :coordinator_session` rows. Default is empty — metering someone's
    `~/.claude` is opt-in.
  * `usage_events.session_id` is indexed, so §7.6's `--by session` is cheap
    when phase 7 adds it.

Three things the implementation found that §7.2's sample does not show, all now
encoded in `ClaudeSessionFile`:

  1. **`cost-state` carries no `timestamp`.** It has `startTime` (epoch ms, the
     CLI *process* start), which is what `:since` windows it by.
  2. **`totalCostUSD` is not monotonic across a file.** It is cumulative within
     one CLI process and **restarts at zero when a new process opens the same
     file** — a real session reads `… 47.41 → 6.63 → 121.02 …`. The file total is
     therefore `sum over startTime segments of max(totalCostUSD)`; maxing the
     whole file would have silently dropped every pre-resume segment.
  3. **Rollover needs a per-line guard, not just `:since`.** A session that rolls
     onto a new id copies the parent's lines into the new file, and the copies
     keep the *parent's* `sessionId`. `read_totals/2` takes `:session_id` and
     skips lines stamped with a different one.

Still open for phase 7: the live HUD tailer (§7.5's "live, approximate" half)
and `arb usage --by session` / `--session <id>` (§7.6).

### 7.8 Post-deploy corrections — what the live run found (bd-be804c, follow-up)

Phase 6 shipped, the coordinator restarted with
`ARBITER_COORDINATOR_SESSION_DIRS` set, and the first live sweep exposed two
defects that no fixture could have predicted. Both are fixed; both changed
assumptions §7.4 states, so they are recorded here rather than in a commit
message.

**1. `cost-state` records are gone in Claude Code 2.1.270.** §7.2's sample and
every fixture came from 2.1.246–2.1.269, which wrote them every few hundred
lines. The 2.1.270 session that was *live at the time of the deploy* — 3,018
lines — contains **zero**, so the authoritative-cost path never fired and every
row landed with `cost_usd: nil`. Six-figure token counts next to no dollars
read as a broken parser, which is worse than the gap phase 6 set out to close.

The fix keeps §7.4's "reuse the CLI's number, don't recompute" rule as the
*first* choice and adds a labelled fallback:
`Arbiter.Usage.ClaudePricing` prices the deduped token buckets at published
list rates when — and only when — the file carries no `cost-state`.
`read_totals/2` reports `cost_source: :cost_state | :estimated | nil`, and
`cost_note_for/1` gives every writer the matching note, so a derived figure is
never mistaken for the CLI's own. An unpriceable model still yields an
explained null. This applies to worker reconciliation too: a worker run on
2.1.270+ now gets a cost instead of a hole.

**2. `occurred_at` must come from the transcript, not the clock.** The first
implementation dated rows `DateTime.utc_now()`. That is within 5 minutes of the
truth in steady state and badly wrong on the first pass: a session that has
been appending since 2026-09-04 had its entire history (16 rows, $739.08 on
the dogfood host) filed on the day the sweeper first ran, falsifying the very
`--by day` column §7.6 promises to fix.

`ClaudeSessionFile` now also splits a file into **UTC-day buckets** — per-day
token counts, per-day message count, the newest turn timestamp in the day, and
that day's apportioned share of the file's one authoritative cost figure (the
total is split, never recomputed). `UsageIngest` writes one row per
(session, day) and dates it at the day's last turn, with the ledger watermark
now read per day, so a delta spanning midnight becomes two correctly dated rows
and a re-run still writes nothing. The rows from the mis-dating deploy are
deleted by
`priv/repo/migrations/20260914060000_redate_coordinator_session_usage.exs` —
they are derived data, so the next sweep re-derives them, on the right days and
with costs.

## 8. Auth modes and Remote Control (AC 10)

### 8.1 The two modes both already exist

`Arbiter.Agents.Claude.ConfigDir` branches on `oauth_token_configured?/1`
(`:169`), and `seed_links/1` (`:469`) implements the other side. What is new here
is **choosing per session** and being explicit about the trade.

| | **Mode A — workspace OAuth token** | **Mode B — seeded user credentials** |
|---|---|---|
| Auth | `CLAUDE_CODE_OAUTH_TOKEN` from workspace `worker_env` | `.credentials.json` copied from the operator's config dir |
| Credential isolation | **Real** — revocable per workspace, distinct from the operator's login | **None** — it is the operator's own grant |
| Remote Control | **Unavailable** (silently — §8.3) | **Works** (measured: 546 bridge records) |
| Metering | Works (measured — §8.3 wrote usage locally) | Works, incl. while bridged (§7.2) |
| Use for | at-desk sessions, untrusted/bulk work | **the default**: any session the operator may need to reach AFK |

### 8.2 Mode B is primary (Amendment 2), and what "isolation" then means

Arbiter is LAN-only and stays that way; the host moves between tailnets; so when
the operator is away, **Remote Control is the only way to reach a session** — and
it needs no inbound ports and outsources remote auth to Anthropic. Since Remote
Control requires mode B (§8.3), **mode B is the default**, not the exception.

State plainly what per-session isolation therefore *is* and *is not*:

- **Not isolated:** the credential. Every mode-B session authenticates as the
  operator. A compromised or runaway session is indistinguishable, upstream, from
  the operator. Quota is shared and exhaustible by any session.
- **Still isolated:** the `CLAUDE_CONFIG_DIR` — settings, permissions, MCP
  registration, session history, and the JSONL that meters it (which is what makes
  per-session metering work at all). The working directory. The MCP scope token.
  The memory layers mounted (§9.4).

One credential hazard to carry over, not re-learn: `ConfigDir` **copies** rather
than symlinks `.credentials.json`, because both sides refresh it and a symlink
would let a session write through and corrupt the operator's login (`:28`, and
`ConfigDir.remove_credentials/1`). Mode-B sessions multiply the number of
independent refreshers of one grant. §12 flags this.

### 8.3 Spike — `--remote-control` under an OAuth token

Predicted: refuses (operator's report). **Observed: worse — it succeeds silently
without a bridge.**

Setup: isolated `CLAUDE_CONFIG_DIR` with **no** `.credentials.json`, a valid
108-char `sk-ant-oat01…` workspace token, run under tmux to provide a TTY
(Claude Code v2.1.270).

| # | Configuration | Observed |
|---|---|---|
| 1 | token, `--print` | **Works.** Returned `SPIKE-OK`, rc=0 — the token is valid. |
| 2 | token, interactive, **fresh** config dir | Login wizard: theme picker → "Select login method" → OAuth URL requesting `…user:sessions:claude_code…`. |
| 3 | token, interactive, `hasCompletedOnboarding: true` seeded | **Works.** Reached a working prompt, "Sonnet 5 · Claude API". |
| 4 | token, interactive, seeded, **`--remote-control`** | **Starts normally. Ran a real turn successfully. Bridge never established.** |

The controls matter: run 2 would have "confirmed" the operator's report for the
wrong reason. The login wizard was a **fresh-config-dir artifact**, not an auth
fact — run 3 shows the token authenticates interactive sessions fine. So the
blocker is the *bridge*, specifically.

Evidence for run 4, measured rather than inferred from the banner:

```
bridge-session records in the session's JSONL : 0     (operator's mode-B session: 546)
bridge* keys in .claude.json                  : NONE  (operator's: bridgeOauthDeadExpiresAt, …)
oauthAccount present                          : False
assistant records carrying usage              : 1     ← metering still worked
```

Re-checked after a further 45 s: still 0. Mechanism: Remote Control needs a
`user:sessions:claude_code`-scoped **user** OAuth grant — the `bridgeOauth*` keys
in `.claude.json` are a separate grant from `CLAUDE_CODE_OAUTH_TOKEN`. A workspace
token does not carry it.

**Design consequences:**

1. `--remote-control` must be **disabled in the UI when mode A is selected**, with
   the reason shown. Offering a toggle that silently does nothing is the worst
   outcome.
2. When mode B + Remote Control is selected, Arbiter must **verify the bridge
   came up** — poll the session JSONL for a `bridge-session` record within a
   timeout and surface `bridge_unavailable` (§5.2 `error`) if absent. Never report
   "reachable remotely" on the strength of having passed a flag.
3. `--remote-control [name]` and `--remote-control-session-name-prefix` let
   Arbiter name sessions; use the Arbiter session id so a claude.ai session is
   traceable back to a row.

## 9. Per-session provisioning (research task 5)

### 9.1 Layout

```
<sessions_root>/<session-id>/
  workspace/            # cwd for the agent; git worktrees created here
    .mcp.json           #   per-session scope token (§9.3) — lives in the cwd
  config/               # CLAUDE_CONFIG_DIR  (isolated, per session)
    .claude.json        #   pre-seeded: onboarding + trust (§9.2)
    settings.json       #   ConfigDir.default_settings_json/0 (:443)
    .credentials.json   #   mode B only — copied, never symlinked
    projects/…/<sid>.jsonl   # the metering + transcript source (§7, §11)
  CLAUDE.md             # generated: role, workspace binding, guardrails
  memory/               # mounted layers + candidate space (§9.4)
  transcript/           # raw PTY byte stream (§11)
```

### 9.2 Pre-seeding is mandatory, and the spike found the exact gates

A fresh `CLAUDE_CONFIG_DIR` **blocks on three interactive prompts** before the
agent is usable (§8.3 runs 2–3). In a browser terminal the operator would just see
a wizard; in an automated launch it hangs forever. The scaffold must pre-write:

| Gate | Key | Where |
|---|---|---|
| Theme picker | `theme` | `<config>/.claude.json` |
| Login method wizard | `hasCompletedOnboarding: true`, `lastOnboardingVersion` | `<config>/.claude.json` |
| "Is this a folder you trust?" | project trust entry for the session cwd | `<config>/.claude.json` |

Verified working in the spike: seeding `hasCompletedOnboarding` took run 2's login
wizard to run 3's working prompt. This is a genuinely new requirement — workers
run `--print`, which never hits these gates, so `ConfigDir` does not seed them
today. It writes `settings.json` (`:443`) but not `.claude.json`. **Extend
`ConfigDir` with an interactive-session variant.**

### 9.3 MCP wiring — per-session, revocable

Reuse `Arbiter.MCP.AgentConfig.Claude.write_mcp_config/2`, which writes `.mcp.json`
with `"type" => "http"` pointing at the loopback MCP endpoint
(`apps/arbiter/lib/arbiter/mcp/agent_config/claude.ex:48`). Unchanged.

**It goes in the session's cwd** (`workspace/`), not at the session root. Claude
Code auto-loads `.mcp.json` from the working directory only, and `launch.sh`
`cd`s into `workspace/` before `exec`ing the agent — a copy one level up is a
copy the session never reads, and the session would start with no Arbiter MCP
server registered at all. This corrects an earlier draft of the §9.1 tree above,
which drew it at the session root.

The token should be **per session and revocable**, not a shared coordinator token:
the session row is the natural revocation handle (killing a session revokes its
token), and per-session tokens make MCP audit rows attributable to the same
`session_id` the ledger uses. Mint at `--tier coordinator`, with
`workspace_id: nil` for the cross-workspace default and a bound `workspace_id`
for the opt-in single-workspace binding (decision 6) — `Arbiter.MCP.Scope` already
models exactly this (`scope.ex:17`).

`can_dispatch` (`scope.ex:20`) is already the documented recursion guardrail and
becomes a pre-launch toggle (§10).

### 9.4 Memory layers (Amendment 3 — decided; implementing, not re-opening)

Per the operator's decision ("a stale memory is worse"), a session mounts memory
**scoped by `metadata.type`**:

| Type | Mounted | Access | Rationale |
|---|---|---|---|
| `user` | always, all sessions | read | who the operator is — behavioural, doesn't rot |
| `feedback` | always, all sessions | read | working doctrine — behavioural, doesn't rot |
| `reference` | always, all sessions | read | pointers to external resources |
| `project` | **only** the session's bound workspace | read | cites `file:line`/modules; rots fast; a vstim session must not load arbiter internals |

**Shared layer is read-mostly.** A session never writes into it. Writes land in a
**per-session candidate space**, on disk at:

```
<sessions_root>/<session-id>/memory/candidates/*.md
```

with the mounted shared layers exposed read-only at
`<sessions_root>/<session-id>/memory/shared/` (bind-mount or symlink; symlink is
sufficient and simpler given the read-only convention is enforced by the generated
`CLAUDE.md`).

This is what makes concurrent sessions safe: `MEMORY.md` is one file edited
without locking, so two sessions writing at once is a last-write-wins clobber —
and decision 2 asks for multiple concurrent sessions, so this is a hard
requirement, not a nicety.

**Explicitly out of scope for this RFC** (per Amendment 3's scope note): the
promotion queue, the staleness checker that quarantines memories whose `file:line`
no longer resolves, and transcript distillation. They appear in the phase table
(§13) as their own children. This RFC builds only the scaffold: which layers
mount, read vs write, and where candidates land.

### 9.6 Status — phase 3 shipped (bd-aprlbb, #1684)

Provisioning is wired into `Arbiter.Sessions.launch/1`: the row is written, the
scaffold is built, then the scope starts. A provisioning failure aborts the
launch and ends the row rather than starting a pane that would hang.

| §9 item | Where it landed |
|---|---|
| 9.1 layout | `Arbiter.Sessions.Layout` (pure paths) + `Arbiter.Sessions.Provisioning` (creation) |
| 9.2 onboarding gates | `Arbiter.Agents.Claude.ConfigDir.Interactive` — merges into `.claude.json` rather than overwriting it, so Claude Code's own state (incl. `bridgeOauth*`) survives a re-provision |
| 9.3 MCP | `Arbiter.MCP.Scope.mint_session/2`; `.mcp.json` written mode `0600` into the session **cwd** via the existing `AgentConfig.Claude.write_mcp_config/2` |
| 9.4 memory | mount points only (`memory/shared`, `memory/candidates`), plus the read-only doctrine in the generated `CLAUDE.md`. No promotion — phase 12 |
| generated instructions | `Arbiter.Sessions.Instructions` |

Two decisions worth carrying forward:

* **Revocation without a revocation table.** Scope tokens are stateless signed
  blobs, and §9.3 asks for a revocable one. Rather than add a table, the token
  carries a `session_id` claim and `Scope.from_token/1` refuses it when the row
  is ended or `mcp_token_revoked_at` is set. Killing a session therefore
  revokes its token by construction, and a token naming a session with no row
  is revoked rather than accepted. The cost is one indexed primary-key read per
  presented **session** token; worker and plain coordinator tokens never touch
  the database.
* **A launch wrapper, not a direct `claude` invocation.** §10.3 forbids a
  credential in argv, and the pane's command line *is* a `tmux -e` list. So
  provisioning writes `launch.sh` (mode `0700`) which sources `auth.env` (mode
  `0600`, mode A only) and `exec`s the agent. The only path in argv is a file
  the operator's user already owns.

§10.2 layers shipped: **1** (scaffolded cwd, and provisioning *refuses* a
sessions root inside the primary checkout rather than warning),
**3** (`Write`/`Edit`/`NotebookEdit` denies under the checkout in the session's
`settings.json`) and **4** (the generated `CLAUDE.md` names the path and the
rule). Layer **2** (worktrees, not the checkout) ships as instruction only —
there is no repo-work surface in phase 3 to enforce it at, and the session's
`workspace/` directory is the place those worktrees go.

### 9.5 Pre-launch UI (decision 5)

| Option | Default |
|---|---|
| Provider | Claude Code |
| Auth mode (A/B) | **B** (§8.2) |
| Remote Control | on when mode B; **disabled with reason** when mode A (§8.3) |
| Workspace binding | cross-workspace; opt-in single workspace |
| `can_dispatch` | **off** (§10) |
| Model / effort | provider defaults |
| Session name | auto (`arb-session-<id>`), editable |
| Working dir | scaffolded (§9.1); choosing an existing checkout is **not** offered (§10) |

## 10. Security and blast radius (research task 6)

### 10.1 Hazard 1 — a session can restart the server hosting it

This is not hypothetical: the coordinator restarted arbiter twice on 2026-09-11
after merging core-app fixes.

The recommendation **converts this from fatal to routine**. Because the PTY is in
a sibling cgroup (§4.1), `systemctl --user restart arbiter` from inside a session
no longer kills that session. It drops the browser's channel; the session keeps
running; the client reconnects with `last_seq` and resumes (§5.3). The operator
sees a brief "reconnecting" state, not a dead terminal.

Remaining guards:

- **Restart recursion.** A session that restarts arbiter on a crash-loop can wedge
  the fleet. Rate-limit: refuse more than N restarts per window from session-origin
  callers, and surface it rather than failing silently.
- **Dispatch recursion.** Already modelled: `can_dispatch` (`scope.ex:20`) is the
  documented coordinator-only guardrail. Default **off**; on is a deliberate
  pre-launch choice.
- **Self-kill.** A session must not be able to terminate *its own* scope through
  Arbiter's API (it would kill the caller mid-call). Reject with a clear error;
  the operator kills it from the dashboard or the CLI.

### 10.2 Hazard 2 — reach into `/home/ryan/dev/arbiter`

Careless edits in the primary checkout have broken the running server before, via
Phoenix hot-reload picking up a half-written file.

Layered, because no single one of these is sufficient:

1. **Scaffold, never point at a checkout** (decision 4). The session's cwd is
   `<sessions_root>/<id>/workspace`, a fresh directory. The pre-launch UI does not
   offer "use an existing checkout" (§9.5).
2. **Worktrees, not the checkout.** Repo work happens in a git worktree created
   under the session root — the same discipline every dispatched worker follows.
3. **Deny-write on the primary checkout.** `ConfigDir.default_settings_json/0`
   (`:443`) already renders hardened settings from `Arbiter.Agents.Claude.Security`;
   extend that policy with a deny rule for writes under the primary `ARB_HOME`
   checkout. Cheap, and catches the accident case.
4. **Generated `CLAUDE.md` states it** (§9.1). Belt and braces — the dispatched-
   worker prompt already carries this warning and it demonstrably helps.

Note honestly: (3) is a *guardrail*, not a sandbox. A session runs as the
operator's user and can reach anything that user can. Real confinement would need
a namespace/container boundary, which is a much larger change and would break the
session's ability to drive `mix`, `git` and `systemctl` — the things it exists to
do. The layered guards target **accidents**, which is the observed failure mode;
they are not a defence against a session acting adversarially.

### 10.3 Credentials reaching the session

Env vars, not proxy-injected headers — the proxy is gone (§2), and it is what
`ConfigDir.env/1` (`:151`) already does. Two rules:

- **Never on a command line.** `/proc/<pid>/cmdline` is world-readable on this
  host, and this repo has a documented incident class around host-wide visible
  process command lines. Pass secrets via the environment or a mode-600 file read
  by the launch wrapper. (The spike did exactly this.)
- **Never in the transcript.** §11.

### 10.4 Loopback only (decision 8)

Bind the session socket to `127.0.0.1:4848` like the rest of the dashboard. No new
remote-auth scheme is designed here; off-LAN access is Remote Control (§8), which
is why Amendment 2 makes it required rather than optional.

## 11. Transcript persistence (research task 7)

Two different artefacts, both wanted, and conflating them is a mistake:

| | **Raw PTY stream** | **Session JSONL** |
|---|---|---|
| Source | `tmux pipe-pane -O` (§4.2) | Claude Code, `<config>/projects/<slug>/<sid>.jsonl` |
| Content | exactly what the operator saw, ANSI and all | structured turns, usage, thinking, tool IO |
| Good for | "what did the screen say", replay | analytics, metering, distillation |
| Location | `<sessions_root>/<id>/transcript/<id>.raw` | archived by bd-db0p38 |

**Relationship to existing artefacts.** Worker runs already produce
`<run_id>.log` (`Arbiter.Worker.OutputLog`, rendered, tool results truncated to 40
lines) and `worker_runs.output_lines` (1000-line tail). The session raw stream is
the analogue of the former but **untruncated**, because a coordinator session has
no run row to summarise into. The JSONL side needs no new machinery at all:
`Arbiter.Worker.SessionArchive` already archives session JSONLs, keyed by run id
— it needs a session-keyed entry point, not a new archiver.

**This is not optional plumbing — it is a deadline.** `docs/session-archive.md`
measured Claude Code pruning its session store at **~21 days**, with 45.2% of
runs carrying a `session_id` having already lost their file. A coordinator session
that is not archived is gone in three weeks, and with it the metering source of
truth and the distillation substrate.

**Size.** Measured on the operator's own sessions: **25 MB / 14,550 lines** for one
long interactive session; 2.2 MB / 1,242 lines for a shorter one. Subagent
transcripts nest separately under `<session-id>/subagents/*.jsonl` (124–208 KB
each in the sample) — session-level archiving must walk them too, as
`SessionArchive.subagents_dir_for/1` already contemplates. The raw PTY stream is
smaller than the JSONL (rendered text, no tool-input duplication) but unbounded in
principle; apply the archive's existing `max_bytes` cap.

**Redaction.** The raw stream captures whatever the screen showed, which can
include a token the operator pasted or a command that echoed a secret. Scrub on
write, and treat the transcript directory as mode-0700 operator-only data. This is
the same posture `docs/worker-security.md` takes.

## 12. Open questions and edge cases

1. **Credential refresh contention (mode B).** Several concurrent sessions each
   hold a *copy* of one `.credentials.json` and each may refresh it. `ConfigDir`
   copies precisely to stop a session corrupting the operator's file (`:28`), but
   whether N independent refreshers of one grant causes upstream rotation churn
   is **not established**. Worth a bounded experiment before running many
   concurrent mode-B sessions. Flagged, not designed around.
2. **Scrollback bound.** 30,000 lines is tmux's default. A week-long session in a
   build loop will exceed it. Raise per session, or accept that deep history lives
   in the transcript and the pane is a window?
3. **Detached-output replay fidelity.** `capture-pane` replays the *rendered pane*,
   so a full-screen TUI mid-redraw replays as its current state — correct, but a
   session in an alternate screen buffer (a pager, an editor) may need
   `-a`/alternate handling. Untested.
4. **Cost-state cadence.** 16 `cost-state` records across 14,550 lines — infrequent
   and evidently not on a fixed interval. The HUD's dollar figure will lag token
   counts. Acceptable, but the HUD should show "as of" rather than implying live
   dollars.
5. **Session-id rollover.** Compaction/`--resume` can change the provider session
   id mid-session (§7.5). The reconciler must follow it or silently stop metering.
6. **`hasUnknownModelCost`.** The cost-state record carries this flag; when true,
   the CLI's dollar figure is incomplete. Map it to the ledger's existing
   `cost_note` (`event.ex:189`) rather than writing a misleading `cost_usd`.
7. **Flaky connections.** Covered by seq-resume (§5.3), but the ring size (2 MB)
   is a guess; measure against a real session before fixing it. *Partly
   defused by phase 4* (§5.5 item 3): `seq` is a byte offset into the pipe
   file, so a reconnect outside the in-memory ring is still served from the
   file rather than repainted. The numbers are in `config/config.exs` under
   `Arbiter.Sessions.Stream` and are still guesses.
8. **Multiple browsers on one session.** tmux supports multi-client attach and
   `resize-window` makes size explicit, but two operators on one session will
   fight over dimensions. Suggested: first client owns size, others letterbox.
   *Decided in phase 4* (§5.5 item 4): the transport does last-writer-wins and
   tells every client the new geometry with `meta`; letterboxing, if wanted, is
   a frontend response to that event.

## 13. Phased implementation plan

Each phase is scoped to one child ticket.

| # | Phase | Scope | Pri | Diff |
|---|---|---|---|---|
| 1 | **Session lifecycle core** | `sessions` table + `Arbiter.Sessions` context; launch via `systemd-run --user --scope` + tmux; adoption sweep on boot; kill. No UI. Tests assert scope/socket naming and re-adoption. | 1 | 3 |
| 2 | **Restart-survival proof in CI** — *shipped (§4.9)* | An integration test that launches a session, restarts a stand-in unit, and asserts survival + gapless replay — the §4.2 spike as a regression test. Cheap, and protects the one property everything else assumes. | 1 | 2 |
| 3 | **Provisioning scaffold** | `arb init`-style per-session layout (§9.1); pre-seed the three onboarding gates (§9.2); `ConfigDir` interactive variant; `.mcp.json` + per-session scope token; mode A/B selection. | 1 | 3 |
| 4 | **Transport** — *shipped (§5.5)* | Socket + channel, full envelope (§5.2), seq ring, resume, backpressure. Tested headlessly against a scripted PTY — no browser needed. | 1 | 3 |
| 5 | **Frontend terminal** | Vendor xterm + canvas addon + CSS; colocated hook; fit/resize; copy-paste; `SessionLive` chrome. | 2 | 3 |
| 6 | **Metering ingest** | Extend `ClaudeSessionFile` to parse `cost-state` (fixes the moduledoc's stated cost gap, benefits workers too); `Sessions.UsageIngest` writing `source: :coordinator_session`; end-of-session reconcile; `session_id` index. | 1 | 3 |
| 7 | **Cost HUD + `arb usage --by session`** | Live `usage` channel events; HUD bar; CLI dimension + `--session` filter (§7.6). | 2 | 2 |
| 8 | **Remote Control integration** | Mode-B launch with `--remote-control <name>`; **bridge verification** via `bridge-session` polling (§8.3); UI disable-with-reason under mode A. | 2 | 2 |
| 9 | **Transcript persistence** | `pipe-pane` raw capture + redaction; session-keyed entry point on `SessionArchive`; subagent walk; retention. | 2 | 2 |
| 10 | **Orphan reaping + CLI fallback** | Idle-deadline sweep; in-scope dead-man's switch; `arb session list/attach` (§4.7). | 2 | 2 |
| 11 | **Pre-launch UI** | The §9.5 option set; guardrail defaults (`can_dispatch` off). | 3 | 2 |
| 12 | **Memory candidate space** | Type-scoped mounts + per-session candidate dir (§9.4) — scaffold only. | 2 | 2 |
| 13 | **Memory promotion + staleness checker** | *Separate ticket.* Promotion queue (`loop_pending_list`/`loop_pending_apply` as UI precedent), `file:line` verification, quarantine-not-serve. | 3 | 4 |
| 14 | **Transcript distillation** | *Separate ticket, later.* Candidate generator only, never a direct writer (Amendment 3.5). Depends on 9 + 13. | 4 | 4 |

Phases 1–2 are the spine: if restart survival regresses, nothing else is worth
having. Phases 13–14 are deliberately outside this RFC per Amendment 3's scope
note.

## 14. Reuse map

| Existing code | `file:line` | Disposition | Why |
|---|---|---|---|
| `Usage.Event` `@sources` (incl. `:coordinator_session`) | `apps/arbiter/lib/arbiter/usage/event.ex:66` | **Reused as-is** | #1596 already added the discriminator; `:45` names this ticket as its writer. No migration. |
| `Usage.Event` `source` attribute | `…/usage/event.ex:130` | **Reused as-is** | Constraint already admits our value. |
| `Usage.Event` `session_id` attribute | `…/usage/event.ex:210` | **Reused as-is**, + one index | Attribution key. Add `[:session_id]` index for `--by session` (§7.4). |
| `Usage.Event` cache-token + `cost_note` attributes | `…/usage/event.ex:176`, `:180`, `:189` | **Reused as-is** | Cache-write/cache-read split already modelled — do not reinvent the pricing arithmetic (§7.4). `cost_note` carries `hasUnknownModelCost` (§12.6). |
| `ClaudeSessionFile.locate/2` | `…/usage/claude_session_file.ex:117` | **Reused as-is** | Globs `projects/*/<sid>.jsonl` under a config dir — exactly the per-session lookup. |
| `ClaudeSessionFile.read_totals/2` | `…/usage/claude_session_file.ex:148` | **Extended** | Dedupe-by-`message.id` and `:since` windowing are correct and load-bearing (§7.5). Extend to parse `cost-state` for `totalCostUSD`/`modelUsage` — its moduledoc's "no per-turn dollar figure" is true of `assistant` lines but **false of the file** (§7.4). Benefits worker reconciliation too. |
| `ConfigDir.oauth_token_configured?/1` (mode A branch) | `apps/arbiter/lib/arbiter/agents/claude/config_dir.ex:169` | **Reused as-is** | Already the mode-A predicate; becomes a per-session choice rather than a global one (§8.1). |
| `ConfigDir.seed_links/2` (mode B branch) | `…/agents/claude/config_dir.ex:469` | **Reused as-is** | Copies (never symlinks) `.credentials.json` — the correct posture, and mode B is now the default (§8.2). |
| `ConfigDir.default_settings_json/0` | `…/agents/claude/config_dir.ex:443` | **Extended** | Writes hardened `settings.json`; extend the policy with a deny-write rule for the primary checkout (§10.2). |
| `ConfigDir.env/1` | `…/agents/claude/config_dir.ex:151` | **Reused as-is** | `CLAUDE_CONFIG_DIR` injection is exactly the isolation mode B still provides (§8.2). |
| *(no existing analogue)* — `.claude.json` onboarding/trust seeding | — | **New** | Workers use `--print` and never hit the interactive gates; sessions block on all three (§9.2). |
| `MCP.AgentConfig.Claude.write_mcp_config/2` (`"type" => "http"`) | `apps/arbiter/lib/arbiter/mcp/agent_config/claude.ex:48` | **Reused as-is** | Per-session `.mcp.json` is the per-spawn case with a different token (§9.3). |
| `MCP.Scope` tiers / `can_dispatch` | `apps/arbiter/lib/arbiter/mcp/scope.ex:17`, `:20` | **Reused as-is** | Already models workspace-agnostic coordinator tokens (decision 6) and the dispatch-recursion guardrail (§10.1). |
| `ClaudeSession.open_port/1` (`Port.open`, `--print`) | `apps/arbiter/lib/arbiter/worker/claude_session.ex:1313` | **Not reused — parallel path** | Port-based, non-interactive, BEAM-owned: no PTY (so no TUI), and BEAM-owned lifetime fails restart survival (§4.4). Worker dispatch keeps it unchanged; sessions take the systemd+tmux path. Its env-injection discipline (`:1354`) is still the reference for §10.3. |
| `Worker.record_usage_event/3` | `apps/arbiter/lib/arbiter/worker.ex:1401` | **Pattern reused, not the code** | Parses the `--print` terminal `result` event, which an interactive session never emits. Sessions use JSONL ingest (§7.1); the ledger-write shape is the model to copy. |
| Claude Code `cost-state` / `usage` / `bridge-session` JSONL records | `<config>/projects/<slug>/<sid>.jsonl` (samples in §7.2) | **New consumer of an existing format** | The metering substrate and the bridge-verification signal (§8.3). |
| `Worker.SessionArchive` | `apps/arbiter/lib/arbiter/worker/session_archive.ex:181`, `:137` | **Extended** | Already archives session JSONLs incl. a subagents dir, keyed by run id; needs a session-keyed entry point (§11). |
| `arb usage` `--by` / `--source` | `apps/arbiter_cli/lib/arbiter_cli/cmd/usage.ex:13`, `:19`, `:32` | **Extended** | `--by source` and `--source coordinator_session` already exist; add `session` (§7.6), following the documented "`--by task` excludes sessionful sources" precedent. |
| `.LogStreamStick` colocated hook | `apps/arbiter_web/lib/arbiter_web/components/core_components/domain.ex:578` | **Pattern reused** | The repo's precedent for a hook owning scroll behaviour on live output (§6.3). |
| esbuild config / vendored JS | `config/config.exs:160`; `apps/arbiter_web/assets/vendor/`, `js/app.js:26` | **Reused as-is** | No `package.json` exists; xterm is vendored like `topbar` (§6.1). |
| `Quota.worker_base_url/1` / metering proxy | *removed in #1605* | **Gone — deliberately not cited** | Per Amendment 4. §7.3 records why re-adding it loses to JSONL ingestion. |
