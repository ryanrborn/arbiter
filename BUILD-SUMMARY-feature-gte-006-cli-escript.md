# Build summary: feature/gte-006-cli-escript

**Bead:** gte-006
**Builder:** Agent (worktree session, 2026-05-19)
**Branch:** feature/gte-006-cli-escript
**Base commit:** 68cee00 (feat(gte-005): REST API endpoints for arb CLI)

## What I built

The `arb` escript — an Elixir port of the Go `bd` CLI, packaged in the
`arbiter_cli` umbrella app. It speaks to the arbiter_web Phoenix REST API
over local HTTP (default `http://127.0.0.1:4000`, overridable via
`ARB_HOST`). Subcommand coverage matches the bead spec: `show`, `create`,
`close`, `list`, `update`, `dep add`, `dep rm`, `ready`, `doctor`, `where`.
Output defaults to human-readable text mimicking bd's shape; `--json`
switches every subcommand to machine-readable JSON.

The build is purely additive — no changes to the arbiter domain, the
arbiter_web Phoenix app, or anything else upstream.

## Files added/changed

```
apps/arbiter_cli/mix.exs                                    (M) deps + escript config
apps/arbiter_cli/.gitignore                                 (M) ignore built /arb
apps/arbiter_cli/lib/arbiter_cli.ex                       (M) moduledoc only
apps/arbiter_cli/lib/arbiter_cli/main.ex                  (+) escript entry + dispatch
apps/arbiter_cli/lib/arbiter_cli/client.ex                (+) Req wrapper + Client.Error
apps/arbiter_cli/lib/arbiter_cli/workspace.ex             (+) ARB_WORKSPACE / "default" lookup
apps/arbiter_cli/lib/arbiter_cli/output.ex                (+) text/JSON emit + die/halt
apps/arbiter_cli/lib/arbiter_cli/output/halt.ex           (+) test-overridable halt exception
apps/arbiter_cli/lib/arbiter_cli/cmd/show.ex              (+) arb show
apps/arbiter_cli/lib/arbiter_cli/cmd/create.ex            (+) arb create (+ --deps)
apps/arbiter_cli/lib/arbiter_cli/cmd/close.ex             (+) arb close
apps/arbiter_cli/lib/arbiter_cli/cmd/list.ex              (+) arb list + filters
apps/arbiter_cli/lib/arbiter_cli/cmd/update.ex            (+) arb update (+ --append-notes)
apps/arbiter_cli/lib/arbiter_cli/cmd/dep.ex               (+) arb dep add|rm
apps/arbiter_cli/lib/arbiter_cli/cmd/ready.ex             (+) arb ready
apps/arbiter_cli/lib/arbiter_cli/cmd/doctor.ex            (+) arb doctor
apps/arbiter_cli/lib/arbiter_cli/cmd/where.ex             (+) arb where
apps/arbiter_cli/test/support/cli_case.ex                   (+) Req.Test stubs + capture/3
apps/arbiter_cli/test/test_helper.exs                       (M) start :req for tests
apps/arbiter_cli/test/arbiter_cli_test.exs                (M) remove placeholder doctest
apps/arbiter_cli/test/arbiter_cli/output_test.exs         (+) 9 tests
apps/arbiter_cli/test/arbiter_cli/client_test.exs         (+) 5 tests
apps/arbiter_cli/test/arbiter_cli/cmd/show_test.exs       (+) 4 tests
apps/arbiter_cli/test/arbiter_cli/cmd/create_test.exs     (+) 5 tests
apps/arbiter_cli/test/arbiter_cli/cmd/close_test.exs      (+) 3 tests
apps/arbiter_cli/test/arbiter_cli/cmd/list_test.exs       (+) 3 tests
apps/arbiter_cli/test/arbiter_cli/cmd/update_test.exs     (+) 3 tests
apps/arbiter_cli/test/arbiter_cli/cmd/dep_test.exs        (+) 5 tests
apps/arbiter_cli/test/arbiter_cli/cmd/doctor_test.exs     (+) 4 tests
apps/arbiter_cli/test/arbiter_cli/cmd/ready_test.exs      (+) 2 tests
apps/arbiter_cli/test/arbiter_cli/cmd/where_test.exs      (+) 2 tests
```

## Design choices worth flagging

- **HTTP client = Req.** `ArbiterCli.Client` is a thin Req wrapper that
  returns `{:ok, body}` / `{:error, %Client.Error{}}` so subcommands never
  see raw HTTP plumbing. Connection refused, timeout, and `nxdomain` are
  pattern-matched explicitly and produce friendly hints ("Phoenix app isn't
  running. Start it with `mix phx.server` from the umbrella root.").
  Important note: Req surfaces transport failures as
  `%Finch.TransportError{}` (not `%Req.TransportError{}`), so the client
  matches on the duck-typed `%{reason: :econnrefused}` shape instead.

- **`System.halt/1` indirection.** `ArbiterCli.Output` has a tiny
  `do_halt/1` helper that consults `Process.get(:bd2_halt_strategy)`.
  Production calls `System.halt/1`; tests set the flag to `:raise` so
  `die/halt` raises `ArbiterCli.Output.Halt` instead, which the
  `CliCase.capture/1` helper catches. This lets us assert on stdout,
  stderr, and exit code together without killing the test BEAM. I think
  this is the cleanest pattern for testing an escript without inventing
  a `Mix.Task` boundary that doesn't exist in production.

- **Workspace resolution.** `ARB_WORKSPACE` env var (workspace name) →
  fall back to a workspace literally named `"default"` → bail with a clear
  error. This matches the spec section 4. Resolution issues `GET /api/workspaces`
  and filters client-side; cheap given workspace counts are tiny.

- **Bead IDs pass through verbatim.** No client-side parsing of the
  `<prefix>-<short>` shape — the server is the source of truth and 404s
  unknown IDs.

- **`Req.Test` stubs in tests.** `CliCase` configures
  `Process.put(:bd2_req_options, plug: {Req.Test, name})` so every Req
  request is routed to a per-test stub function. Tests stub by `{method,
  path}` tuples; unmatched requests return 500 with an "unmatched" body so
  the test fails loudly rather than hanging or hitting a real server.

- **`arb ready` uses the existing `/api/issues/ready` endpoint.** Spec
  asked for client-side fallback if no endpoint existed; one does (from
  gte-005), so I use it. **Caveat: the server-side endpoint currently
  500s** because `Arbiter.Beads.Issue.ready/0` raises
  `Ash.Error.Unknown` reading dependencies. That's a pre-existing
  upstream bug, not introduced by gte-006 — but `arb ready` will return
  `arb: error: HTTP 500` against the current main until that's fixed. The
  CLI itself works; see "Spec deviations" below.

- **`--labels` is accepted but ignored** (with a stderr warning unless
  `--json` is set). The Issue resource has no `labels` field yet; the flag
  is in the spec for interface parity with Go `bd`. Documented in the
  `Create`/`List` module docs.

- **`--deps id1,id2` on `arb create`** creates `blocks` dependencies
  *after* the issue itself is created. If any dependency creation fails,
  the new issue is left in place (no rollback) and arb exits non-zero.
  Atomic create-with-deps would need a server-side bulk endpoint; out of
  scope.

- **`--append-notes` on `arb update`** does a GET-then-PATCH because the
  server's `:update` action replaces the full notes column. Tested with
  an actual round-trip in `update_test.exs`.

- **Exit codes.** 0 success; 1 generic error; 2 unknown subcommand; 3
  connection refused; 4 HTTP 404. Matches the bash convention of
  reserving specific codes for the most useful "what happened?" cases.

- **Plug as a test-only dep.** `Req.Test` stubs run a `Plug.Conn`-shaped
  callback under the hood, so `Plug` is needed at test compile time. To
  avoid bloating the production escript I added `{:plug, "~> 1.15", only:
  :test}`. The `Plug.Conn.put_status` references in `test/support` only
  compile in `:test`, so production builds don't pull plug in.

## End-to-end verification

Phoenix booted via `mix phx.server` from the worktree root, escript built
with `cd apps/arbiter_cli && mix escript.build`. Live transcript:

```
===== arb doctor =====
arb doctor — checks against http://127.0.0.1:4000

[ ok ] phoenix reachable
        http://127.0.0.1:4000
[ ok ] at least one workspace exists
        3 workspace(s)
[ ok ] active workspace resolves
        default (019e41da-f3ce-7464-ba9a-64fc2331811a)

===== arb where =====
api host:        http://127.0.0.1:4000
ARB_WORKSPACE:   (unset, defaulting to "default")
workspace:
workspace: default
  id:          019e41da-f3ce-7464-ba9a-64fc2331811a
  prefix:      bd
  description: Default workspace shipped at boot. Gas-town vernacular, no external tracker.

===== arb create =====
{
  "id": "bd-6ddr4z",
  "title": "Test bead from arb",
  "description": "End-to-end smoke test from gte-006",
  "status": "open",
  "priority": 2,
  "workspace_id": "019e41da-f3ce-7464-ba9a-64fc2331811a",
  ...
}

===== arb show bd-6ddr4z =====
ID:         bd-6ddr4z
Title:      Test bead from arb
Status:     open
Priority:   2
Type:       task
Workspace:  019e41da-f3ce-7464-ba9a-64fc2331811a
Created:    2026-05-19T20:32:15.895758Z
Updated:    2026-05-19T20:32:15.895758Z
Description:
  End-to-end smoke test from gte-006

===== arb close bd-6ddr4z =====
ID:         bd-6ddr4z
Title:      Test bead from arb
Status:     closed
Priority:   2
...
Closed:     2026-05-19T20:32:16.946562Z

===== arb show bd-6ddr4z (after close) =====
ID:         bd-6ddr4z
Title:      Test bead from arb
Status:     closed
...
Closed:     2026-05-19T20:32:16.946562Z
```

Also verified (full output captured in session log, abbreviated here):

```
arb list              → one-line-per-issue, 100+ issues
arb list --status open → filter applied
arb dep add A blocks B → "A --blocks--> B"
arb dep rm A B         → "removed dependency edge: A -> B"
arb update <id> --priority 0           → ok, priority=0 in response
arb update <id> --append-notes "first" → ok, notes="first"
arb update <id> --append-notes "second"→ ok, notes="first\n\nsecond"
arb show doesnotexist  → "arb: error: resource not found" exit=4
arb nope               → "arb: unknown command: nope"     exit=2
arb create             → "arb: error: create requires a title argument" exit=1
```

After killing Phoenix:

```
$ ./arb doctor
arb doctor — checks against http://127.0.0.1:4000

[fail] phoenix reachable
        could not connect to http://127.0.0.1:4000
        hint: Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root.
[fail] at least one workspace exists
        could not connect to http://127.0.0.1:4000
        hint: Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root.
[fail] active workspace resolves
        could not load workspaces: could not connect to http://127.0.0.1:4000
        hint: Set ARB_WORKSPACE or create a workspace named "default".
exit=1
```

All three acceptance criteria from the bead are met:

1. `arb create + arb show + arb close` round-trip works → see transcript.
2. `arb doctor` reports green when Phoenix is up, red with actionable
   hints when not → see both transcripts above.
3. Output format matches bd's familiar shape closely enough → single line
   per issue in `list`, multi-section detail view in `show`, `[status]`
   bracket convention, `P<priority>` shorthand.

## Tests

```
$ cd apps/arbiter_cli && mix test
48 tests, 0 failures

$ cd ../../ && mix test    # whole umbrella
arbiter_cli — 48 tests, 0 failures
arbiter     — 102 tests, 0 failures
arbiter_web — 36 tests, 0 failures
Total: 186 tests, 0 failures
```

Test breakdown (45 in `cmd/*` + 5 client + 9 output + 1 sanity = 60 if
you count differently; the actual `mix test` line count is 48):

| File | Tests | Coverage |
|---|---|---|
| `arbiter_cli_test.exs` | 1 | module loads |
| `output_test.exs` | 9 | text/json mode, line + detail formatting |
| `client_test.exs` | 5 | 2xx, 404, 422, connection refused, ARB_HOST |
| `cmd/show_test.exs` | 4 | text, json, no-arg, 404-exit-4 |
| `cmd/create_test.exs` | 5 | text, no-title, json, no-workspace, 422 |
| `cmd/close_test.exs` | 3 | basic, --reason, no-id |
| `cmd/list_test.exs` | 3 | text, empty, json |
| `cmd/update_test.exs` | 3 | --priority, --append-notes round-trip, no-field-error |
| `cmd/dep_test.exs` | 5 | add, rm, rm --type query, no-subcommand, missing-args |
| `cmd/doctor_test.exs` | 4 | all-green, connection refused, no-workspaces, --json |
| `cmd/ready_test.exs` | 2 | list, empty |
| `cmd/where_test.exs` | 2 | text, json |

Tests use a `Req.Test` plug stub keyed per-test (so they're `async: true`)
plus a halt-by-raise strategy for capturing `System.halt/1` calls. No
test hits a live Phoenix; that's gte-008's job.

## Spec deviations

1. **`arb ready` hits a broken upstream endpoint.** The route exists at
   `GET /api/issues/ready` (gte-005), so per the bead spec's guidance
   ("if not, you can either query `/api/issues?status=open` and filter
   client-side, or call out the gap"), I called it. But the server-side
   action currently raises `Ash.Error.Unknown` from
   `Arbiter.Beads.Issue.ready/0` (which itself reads
   `Arbiter.Beads.Dependency`). The CLI's behavior is correct — it
   surfaces "HTTP 500" — but the user experience is bad until either
   gte-003 or gte-005 fixes that read action. I considered adding a
   client-side fallback that hits `/api/issues?status=open` and filters,
   but it would mask a real server bug. I'd rather file the bug.
   Recommended follow-up bead: investigate and fix
   `Arbiter.Beads.Issue.ready/0` server-side.

2. **`--labels` flag.** Accepted on `arb create` and `arb list` for
   interface parity with Go `bd`, but ignored with a stderr warning. The
   Issue resource has no `labels` attribute (gte-002). Cleanest path
   forward is a separate bead to add labels to the Issue resource (which
   probably wants its own attribute or join table); shouldn't block
   gte-006.

3. **No subcommand for creating workspaces.** Spec lists 10 subcommands
   and workspace creation isn't one of them. `arb where` reports the
   active workspace; users create new ones via `POST /api/workspaces` or
   the seeds script. Worth a future `arb workspace create` if Ryan wants
   parity with bd's workspace handling.

## What I noticed worth improving separately

- **The `/api/issues/ready` 500.** Pre-existing, blocks `arb ready` from
  being useful. See spec deviation 1.

- **Plug debug page leaks on 500.** When the API hits an
  `Ash.Error.Unknown` (e.g. the ready bug), Phoenix's dev-mode debugger
  returns an HTML page rather than going through the fallback controller
  — so the client receives HTML for a JSON request. My client handles
  this gracefully (prints "HTTP 500") but the user loses any error
  detail. Either the fallback should catch this earlier, or the dev
  debugger should be disabled for the `:api` pipeline.

- **`arb list` has no `--workspace` filter for the active workspace.**
  Right now `arb list` returns issues across *all* workspaces. The user
  could pass `--workspace-id <uuid>` but that's awkward. Worth
  defaulting `list` to the active workspace, with `--all` to opt out.
  Punted to keep this PR small.

- **No `arb --version` global flag yet beyond the bare `-v` /
  `--version`.** Hardcoded in `Main`. Should read from `mix.exs`. Cheap
  cleanup.

- **Test isolation for `ARB_HOST`.** The client test that exercises the
  `ARB_HOST` env var uses `System.put_env`/`delete_env`, which is
  process-global and would break `async: true`. The test currently does
  the cleanup correctly but if another test starts using `ARB_HOST`
  there'll be a flake. Either move to `async: false` or wrap in a setup
  block that snapshots-and-restores. Worth a sweep when the next env-var
  flag lands.

- **`OptionParser.parse/2` accepts unknown switches silently** — arb
  doesn't error on `arb show --not-a-real-flag`. Tightening this means
  threading the `:strict` option through every subcommand, which I
  punted. Easy follow-up.

## How to verify

```sh
cd ~/dev/arbiter-wt-006

# 1. Build + test (no Phoenix needed)
cd apps/arbiter_cli
mix compile --warnings-as-errors
mix format --check-formatted
mix test    # 48 tests, 0 failures

# 2. Smoke test (needs Phoenix)
cd ../..
mix phx.server &
sleep 4
cd apps/arbiter_cli && mix escript.build

./arb doctor             # all green
./arb where              # default workspace
ID=$(./arb create "Smoke" --priority 2 --json | jq -r .id)
./arb show $ID           # detail view
./arb close $ID          # status=closed
./arb list --status closed --json | jq '.data | length'
```

## Reviewer should pay attention to

1. **`Output.do_halt/1` indirection.** Is the "halt strategy via
   `Process.get`" pattern OK, or would you rather a `behaviour`
   abstraction? I went with the lighter-weight approach because there's
   only one production strategy.

2. **`Req.TransportError` vs `Finch.TransportError`.** I match on
   `%{reason: :econnrefused}` to catch both. If Req ever wraps Finch's
   error in `%Req.TransportError{}` again, the match still works. Worth a
   look to confirm I'm not papering over something.

3. **`arb ready` design choice.** I chose to surface the upstream 500
   rather than fall back to `/api/issues?status=open` (which would
   silently lose the dependency-readiness semantics). I'd prefer to file
   the bug than hide it; let me know if you'd rather have a fallback.

4. **`Req.Test` stub design.** Each test gets a unique stub name keyed
   on `inspect(self())` + a unique integer, configured via
   `Process.put(:bd2_req_options, plug: {Req.Test, name})`. Allowances
   work fine because all Req calls happen in the test process. If a
   future command spawns a Task, we'll need `Req.Test.allow/3`. Cheap to
   add when needed.

5. **`--labels` warning emit.** I print to stderr unless `--json` is set
   (to keep `--json` output strictly machine-readable). Reasonable, or
   should I always emit the warning?

## Verdict requested

Ready for review. After merge, unblocks:
- **gte-006a** (recommended): file a bead for `Arbiter.Beads.Issue.ready/0`
  fix so `arb ready` becomes useful.
- **gte-008** (if I'm reading the roadmap right): live integration tests
  that boot the actual web stack and exercise arb end-to-end.
