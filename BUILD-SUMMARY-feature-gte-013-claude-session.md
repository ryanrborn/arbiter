# Build summary: feature/gte-013-claude-session

**Bead:** gte-013
**Builder:** Mayor (interactive session, 2026-05-20)
**Branch:** feature/gte-013-claude-session
**Commits:**
- `cee3b0c` — feat(gte-013): impl + tests
- (this commit) — feat(gte-013): BUILD-SUMMARY

## What I built

`Arbiter.Polecat.ClaudeSession` — the polecat's I/O surface. Wraps an
Erlang `Port` around a child process (Claude Code CLI later, an echo
fixture for now), streams its stdout into the owning `Polecat` GenServer,
broadcasts each line over `Phoenix.PubSub`, and detects a `gt done`
completion marker that auto-transitions the polecat to `:completed`.

This is Phase 2's spike-first deliverable: validate Port semantics with
shell fixtures, then drop in real Claude later by changing the default
argv.

### Files added

```
apps/arbiter/lib/arbiter/polecat/claude_session.ex   (+) ~210 LOC
apps/arbiter/test/fixtures/echo_with_done.sh           (+) shell fixture
apps/arbiter/test/arbiter/polecat/claude_session_test.exs   (+) 14 tests
```

### Files modified

```
apps/arbiter/lib/arbiter/polecat.ex
  + State struct now carries `claude_sessions: %{}` (port -> session map)
  + handle_call({:__claude_session_open__, port_args, session_config}, ...)
  + handle_info({port, {:data, {:eol, line}}}, ...)
  + handle_info({port, {:data, {:noeol, partial}}}, ...)
  + handle_info({port, {:exit_status, status}}, ...)
  + handle_info({:__claude_session_done__, _line}, ...) — auto-complete
  + private helpers: on_port_data/3, sync_session_meta/2, maybe_put/3
```

**Polecat's public API is unchanged.** Existing tests (245 in
`arbiter`, plus the rest of the umbrella) stay green untouched.

## Public API (new)

```elixir
Arbiter.Polecat.ClaudeSession.start(opts) :: {:ok, port()} | {:error, term()}

# opts:
#   owner:         pid()              REQUIRED — the polecat GenServer
#   worktree_path: String.t()         REQUIRED — must exist (cwd for the child)
#   command:       [String.t()] | nil OVERRIDE — full argv; tests always set this
#   prompt:        String.t()         REQUIRED iff command is nil; becomes
#                                     ["claude", "--print", prompt]
#   topic:         String.t() | nil   defaults to "polecat:<bead_id>"
```

## Architecture (one diagram, then prose)

```
caller (anything, e.g. a workflow runner)
  │
  ▼
ClaudeSession.start(owner: polecat_pid, ...)
  │   GenServer.call(polecat, {:__claude_session_open__, ...})
  ▼
polecat handle_call         ─── Port.open/2 — POLECAT becomes the port owner
  │
  ▼
polecat handle_info({port, ...})
  │
  ├── data {:eol, line}  → append to session.output_lines (cap @ 1000)
  │                        Phoenix.PubSub.broadcast {:polecat_output, ...}
  │                        if line =~ ~r/\bgt done\b/, send self() :__claude_session_done__
  ├── data {:noeol, _}   → same path (partial lines also stream)
  ├── exit_status n      → session.exit_status = n
  │                        Phoenix.PubSub.broadcast {:polecat_exited, ...}
  └── :__claude_session_done__ → if status == :running, transition to :completed
                                 with meta[:result] = :claude_done
```

**Why the `GenServer.call` hop?** Port messages flow only to the port
owner. If `ClaudeSession.start/1` opened the port in the caller's
process and then tried to `Port.connect/2` ownership over to the
polecat, we'd race the ownership transfer against the first burst of
child output. By opening the port from inside the polecat's
`handle_call`, the polecat is the owner from the first byte. The
call is synchronous from the caller's perspective, which is the same
contract the spec asked for.

## Design choices worth flagging

### 1. The "gt done" detection regex

```elixir
@done_regex ~r/\bgt done\b/
```

Word-bounded. Matches `gt done`, `>> gt done <<`, `[gt done]`,
`Status: gt done`. Does NOT match `running gt done-style flows` (the
hyphen breaks the word boundary on the right), and would not match
`giga-tonne done` (no `gt` token).

**Risk**: real Claude transcripts may casually mention "gt done" in
prose ("…and then you'd run `gt done` to close it…"). The bead asked
the reviewer to weigh this. Two cheap tightenings if it bites us:
- Anchor to start-of-line: `~r/^\s*gt done\s*$/`
- Anchor to a sentinel prefix: `~r/^>>>\s*gt done\s*<<<$/` and have
  the prompt instruct Claude to emit that sentinel literally.

I picked the looser regex because the bead said *either* form, the
spike doesn't yet have real Claude output to calibrate against, and
the stricter forms are an easy follow-up.

### 2. Output buffering cap (1000 lines)

```elixir
@line_cap 1000
```

Stored newest-first in `session.output_lines` for O(1) prepend; the
list is reversed when mirrored into `meta[:output_lines]` so consumers
see oldest-first. When the list grows past 1000, the OLDEST entries
fall off (we `Enum.take(_, cap)` after prepending). The cap test
verifies this directly.

**Risk**: no back-pressure. We never block on slow consumers. A
runaway child that emits 100k lines/sec just churns the prepend-and-
truncate loop. For Phase 2 spike use this is fine. If we ever drive
this from a CI runner with megabyte-per-second output we'll want a
streaming sink (file? batched writes?) rather than holding everything
in memory.

### 3. PubSub topic default: `"polecat:<bead_id>"`

`Phoenix.PubSub` instance is `Arbiter.PubSub` (verified in
`apps/arbiter/lib/arbiter/application.ex`; the bead's hint of
`ArbiterWeb.PubSub` was wrong — the actual PubSub lives in the core
app, not the web app).

Subscribers discover the topic the same way they discover the polecat:
**by bead_id**. LiveView for bead `gte-013` subscribes to
`"polecat:gte-013"`. The override (`:topic` opt) exists for tests and
for any future case where two surfaces want different namespaces.

Broadcast is unconditional. If nobody's subscribed, `Phoenix.PubSub`
returns `:ok` without doing real work.

### 4. State extension vs meta pollution

I added a `claude_sessions: %{}` field to `Polecat.State` rather than
stashing per-port state inside `meta`. Two reasons:

- The bead's existing `meta == %{}` assertion in `polecat_test.exs`
  would break if we always populated meta with a sessions map.
- Per-port internals (regex, line cap) are not snapshot-worthy; they're
  implementation detail of this module, not workflow state.

The *useful* fields (output_lines, exit_status, exited_at) ARE mirrored
into `meta` via `sync_session_meta/2`, so callers reading
`Polecat.state(pid).meta` see exactly what the bead spec promised:
`output_lines`, `exit_status`, `exited_at`.

### 5. Additive handle_info clauses

Before this bead, `Polecat` had **zero** `handle_info` clauses. All my
new clauses pattern-match on either `{port, ...}` (where `port` is
guarded `is_port/1`) or `{:__claude_session_done__, _}`. Nothing
shadows future additions; nothing catches arbitrary messages with a
catch-all. If a future bead adds `handle_info({:tick, _}, state)`, it
slots in alongside cleanly.

### 6. Error handling on port open

`Port.open/2` raises on a bad executable path. I `rescue` and return
`{:error, {:port_open_failed, msg}}` from inside the handle_call so the
caller gets a tagged tuple instead of a process crash. The argv-resolve
step (`System.find_executable/1`) is the first line of defense and
catches the common case — the `rescue` is a belt-and-suspenders for
edge cases like a binary that disappears between `find_executable` and
`Port.open` (permissions change, etc.).

## Test coverage

14 tests in `apps/arbiter/test/arbiter/polecat/claude_session_test.exs`:

| Block | Count | Covers |
|---|---|---|
| `start/1` | 4 | success returns `{:ok, port}`; missing executable; missing worktree; missing `:owner` |
| `output streaming` | 3 | lines append to `meta[:output_lines]` in order; `:polecat_output` broadcast; default topic discovery |
| `completion detection` | 2 | `gt done` line auto-completes a `:running` polecat; auto-complete suppressed when polecat is `:idle` (illegal transition) |
| `exit handling` | 3 | `meta[:exit_status]` captured; `:polecat_exited` broadcast; non-zero exit propagates (exit 42) |
| `buffering` | 1 | line cap enforced — emit cap+50 lines, exactly cap retained, oldest dropped |
| `concurrent polecats` | 1 | two polecats with two ports — each only sees its own output, each PubSub topic isolated |

`async: false` (Port + PubSub + Polecat registry are all globals). Each
test uses a unique bead_id and a per-test tmp dir for cwd; `on_exit`
cleans them up.

## Verification

```
mix compile --warnings-as-errors                                    # clean
mix format --check-formatted <my 3 files>                           # clean
mix test apps/arbiter/test/arbiter/polecat/claude_session_test.exs   # 14 / 0
mix test                                                            # umbrella: 329 / 0
                                                                    # (arbiter 245, arbiter_cli 48, arbiter_web 36)
```

`mix format --check-formatted` on the umbrella flags four files that
pre-date this branch (migrations, mapper_test, trackers_test,
import_from_dolt). I confirmed by stashing and re-running — same diff
on `HEAD~`. Not part of this bead.

## What's NOT in this bead

- **No real Claude invocation.** Default argv is
  `["claude", "--print", prompt]` but every test passes `:command`
  explicitly. Smoke-testing against real Claude is a separate spike.
- **No worktree wiring.** `ClaudeSession` takes a `worktree_path:`
  string; how that path is created (gte-009) and which polecat owns
  which worktree is the orchestrator's problem.
- **No prompt-template logic.** Whatever the caller passes as `:prompt`
  is what Claude sees, verbatim.
- **No retry / restart on child crash.** If the child exits non-zero,
  `meta[:exit_status]` records it and life goes on. The workflow layer
  decides what to do (probably `Polecat.fail/2`).
- **No multi-session-per-polecat semantics yet.** The `claude_sessions`
  map is keyed by port so the data structure supports it, but
  `sync_session_meta/2` just mirrors the most recently-touched session
  into `meta`. If a polecat ever runs two children in parallel we'll
  want a richer surface.

## For the reviewer

The three things worth your time:

1. **The `gt done` regex.** Is `~r/\bgt done\b/` loose enough to catch
   real completion markers and tight enough to avoid prose false
   positives? Section "Design choices > 1" lists two cheap tightenings.
2. **The 1000-line cap and the lack of back-pressure.** Will this hold
   for real Claude sessions (typical output volume)? Section "Design
   choices > 2" sketches the failure mode.
3. **The PubSub topic convention.** `"polecat:<bead_id>"` is the
   discovery contract. Subscribers find topics the same way they find
   polecats — by bead_id. If LiveView or the CLI follower wants a
   different namespace, this is the moment to push back.

Also worth a glance: the additive `handle_info` clauses in
`polecat.ex`. Polecat had zero `handle_info` clauses before; mine all
match on `{port, _}` (guarded `is_port/1`) or `:__claude_session_done__`,
no catch-alls, so future clauses slot in cleanly.
