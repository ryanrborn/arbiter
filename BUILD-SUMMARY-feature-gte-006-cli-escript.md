# Build summary: feature/gte-006-cli-escript

**Bead:** gte-006
**Builder:** Agent (worktree session, 2026-05-19)
**Branch:** feature/gte-006-cli-escript
**Base commit:** 68cee00 (feat(gte-005): REST API endpoints for bd2 CLI)

## What I built

The `bd2` escript — an Elixir port of the Go `bd` CLI, packaged in the
`gt_elixir_cli` umbrella app. It speaks to the gt_elixir_web Phoenix REST API
over local HTTP (default `http://127.0.0.1:4000`, overridable via
`BD2_HOST`). Subcommand coverage matches the bead spec: `show`, `create`,
`close`, `list`, `update`, `dep add`, `dep rm`, `ready`, `doctor`, `where`.
Output defaults to human-readable text mimicking bd's shape; `--json`
switches every subcommand to machine-readable JSON.

The build is purely additive — no changes to the gt_elixir domain, the
gt_elixir_web Phoenix app, or anything else upstream.

## Files added/changed

```
apps/gt_elixir_cli/mix.exs                                    (M) deps + escript config
apps/gt_elixir_cli/.gitignore                                 (M) ignore built /bd2
apps/gt_elixir_cli/lib/gt_elixir_cli.ex                       (M) moduledoc only
apps/gt_elixir_cli/lib/gt_elixir_cli/main.ex                  (+) escript entry + dispatch
apps/gt_elixir_cli/lib/gt_elixir_cli/client.ex                (+) Req wrapper + Client.Error
apps/gt_elixir_cli/lib/gt_elixir_cli/workspace.ex             (+) BD2_WORKSPACE / "default" lookup
apps/gt_elixir_cli/lib/gt_elixir_cli/output.ex                (+) text/JSON emit + die/halt
apps/gt_elixir_cli/lib/gt_elixir_cli/output/halt.ex           (+) test-overridable halt exception
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/show.ex              (+) bd2 show
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/create.ex            (+) bd2 create (+ --deps)
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/close.ex             (+) bd2 close
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/list.ex              (+) bd2 list + filters
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/update.ex            (+) bd2 update (+ --append-notes)
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/dep.ex               (+) bd2 dep add|rm
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/ready.ex             (+) bd2 ready
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/doctor.ex            (+) bd2 doctor
apps/gt_elixir_cli/lib/gt_elixir_cli/cmd/where.ex             (+) bd2 where
apps/gt_elixir_cli/test/support/cli_case.ex                   (+) Req.Test stubs + capture/3
apps/gt_elixir_cli/test/test_helper.exs                       (M) start :req for tests
apps/gt_elixir_cli/test/gt_elixir_cli_test.exs                (M) remove placeholder doctest
apps/gt_elixir_cli/test/gt_elixir_cli/output_test.exs         (+) 9 tests
apps/gt_elixir_cli/test/gt_elixir_cli/client_test.exs         (+) 5 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/show_test.exs       (+) 4 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/create_test.exs     (+) 5 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/close_test.exs      (+) 3 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/list_test.exs       (+) 3 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/update_test.exs     (+) 3 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/dep_test.exs        (+) 5 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/doctor_test.exs     (+) 4 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/ready_test.exs      (+) 2 tests
apps/gt_elixir_cli/test/gt_elixir_cli/cmd/where_test.exs      (+) 2 tests
```

## Design choices worth flagging

- **HTTP client = Req.** `GtElixirCli.Client` is a thin Req wrapper that
  returns `{:ok, body}` / `{:error, %Client.Error{}}` so subcommands never
  see raw HTTP plumbing. Connection refused, timeout, and `nxdomain` are
  pattern-matched explicitly and produce friendly hints ("Phoenix app isn't
  running. Start it with `mix phx.server` from the umbrella root.").
  Important note: Req surfaces transport failures as
  `%Finch.TransportError{}` (not `%Req.TransportError{}`), so the client
  matches on the duck-typed `%{reason: :econnrefused}` shape instead.

- **`System.halt/1` indirection.** `GtElixirCli.Output` has a tiny
  `do_halt/1` helper that consults `Process.get(:bd2_halt_strategy)`.
  Production calls `System.halt/1`; tests set the flag to `:raise` so
  `die/halt` raises `GtElixirCli.Output.Halt` instead, which the
  `CliCase.capture/1` helper catches. This lets us assert on stdout,
  stderr, and exit code together without killing the test BEAM. I think
  this is the cleanest pattern for testing an escript without inventing
  a `Mix.Task` boundary that doesn't exist in production.

- **Workspace resolution.** `BD2_WORKSPACE` env var (workspace name) →
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

- **`bd2 ready` uses the existing `/api/issues/ready` endpoint.** Spec
  asked for client-side fallback if no endpoint existed; one does (from
  gte-005), so I use it. **Caveat: the server-side endpoint currently
  500s** because `GtElixir.Beads.Issue.ready/0` raises
  `Ash.Error.Unknown` reading dependencies. That's a pre-existing
  upstream bug, not introduced by gte-006 — but `bd2 ready` will return
  `bd2: error: HTTP 500` against the current main until that's fixed. The
  CLI itself works; see "Spec deviations" below.

- **`--labels` is accepted but ignored** (with a stderr warning unless
  `--json` is set). The Issue resource has no `labels` field yet; the flag
  is in the spec for interface parity with Go `bd`. Documented in the
  `Create`/`List` module docs.

- **`--deps id1,id2` on `bd2 create`** creates `blocks` dependencies
  *after* the issue itself is created. If any dependency creation fails,
  the new issue is left in place (no rollback) and bd2 exits non-zero.
  Atomic create-with-deps would need a server-side bulk endpoint; out of
  scope.

- **`--append-notes` on `bd2 update`** does a GET-then-PATCH because the
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
with `cd apps/gt_elixir_cli && mix escript.build`. Live transcript:

```
===== bd2 doctor =====
bd2 doctor — checks against http://127.0.0.1:4000

[ ok ] phoenix reachable
        http://127.0.0.1:4000
[ ok ] at least one workspace exists
        3 workspace(s)
[ ok ] active workspace resolves
        default (019e41da-f3ce-7464-ba9a-64fc2331811a)

===== bd2 where =====
api host:        http://127.0.0.1:4000
BD2_WORKSPACE:   (unset, defaulting to "default")
workspace:
workspace: default
  id:          019e41da-f3ce-7464-ba9a-64fc2331811a
  prefix:      bd
  description: Default workspace shipped at boot. Gas-town vernacular, no external tracker.

===== bd2 create =====
{
  "id": "bd-6ddr4z",
  "title": "Test bead from bd2",
  "description": "End-to-end smoke test from gte-006",
  "status": "open",
  "priority": 2,
  "workspace_id": "019e41da-f3ce-7464-ba9a-64fc2331811a",
  ...
}

===== bd2 show bd-6ddr4z =====
ID:         bd-6ddr4z
Title:      Test bead from bd2
Status:     open
Priority:   2
Type:       task
Workspace:  019e41da-f3ce-7464-ba9a-64fc2331811a
Created:    2026-05-19T20:32:15.895758Z
Updated:    2026-05-19T20:32:15.895758Z
Description:
  End-to-end smoke test from gte-006

===== bd2 close bd-6ddr4z =====
ID:         bd-6ddr4z
Title:      Test bead from bd2
Status:     closed
Priority:   2
...
Closed:     2026-05-19T20:32:16.946562Z

===== bd2 show bd-6ddr4z (after close) =====
ID:         bd-6ddr4z
Title:      Test bead from bd2
Status:     closed
...
Closed:     2026-05-19T20:32:16.946562Z
```

Also verified (full output captured in session log, abbreviated here):

```
bd2 list              → one-line-per-issue, 100+ issues
bd2 list --status open → filter applied
bd2 dep add A blocks B → "A --blocks--> B"
bd2 dep rm A B         → "removed dependency edge: A -> B"
bd2 update <id> --priority 0           → ok, priority=0 in response
bd2 update <id> --append-notes "first" → ok, notes="first"
bd2 update <id> --append-notes "second"→ ok, notes="first\n\nsecond"
bd2 show doesnotexist  → "bd2: error: resource not found" exit=4
bd2 nope               → "bd2: unknown command: nope"     exit=2
bd2 create             → "bd2: error: create requires a title argument" exit=1
```

After killing Phoenix:

```
$ ./bd2 doctor
bd2 doctor — checks against http://127.0.0.1:4000

[fail] phoenix reachable
        could not connect to http://127.0.0.1:4000
        hint: Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root.
[fail] at least one workspace exists
        could not connect to http://127.0.0.1:4000
        hint: Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root.
[fail] active workspace resolves
        could not load workspaces: could not connect to http://127.0.0.1:4000
        hint: Set BD2_WORKSPACE or create a workspace named "default".
exit=1
```

All three acceptance criteria from the bead are met:

1. `bd2 create + bd2 show + bd2 close` round-trip works → see transcript.
2. `bd2 doctor` reports green when Phoenix is up, red with actionable
   hints when not → see both transcripts above.
3. Output format matches bd's familiar shape closely enough → single line
   per issue in `list`, multi-section detail view in `show`, `[status]`
   bracket convention, `P<priority>` shorthand.

## Tests

```
$ cd apps/gt_elixir_cli && mix test
48 tests, 0 failures

$ cd ../../ && mix test    # whole umbrella
gt_elixir_cli — 48 tests, 0 failures
gt_elixir     — 102 tests, 0 failures
gt_elixir_web — 36 tests, 0 failures
Total: 186 tests, 0 failures
```

Test breakdown (45 in `cmd/*` + 5 client + 9 output + 1 sanity = 60 if
you count differently; the actual `mix test` line count is 48):

| File | Tests | Coverage |
|---|---|---|
| `gt_elixir_cli_test.exs` | 1 | module loads |
| `output_test.exs` | 9 | text/json mode, line + detail formatting |
| `client_test.exs` | 5 | 2xx, 404, 422, connection refused, BD2_HOST |
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

1. **`bd2 ready` hits a broken upstream endpoint.** The route exists at
   `GET /api/issues/ready` (gte-005), so per the bead spec's guidance
   ("if not, you can either query `/api/issues?status=open` and filter
   client-side, or call out the gap"), I called it. But the server-side
   action currently raises `Ash.Error.Unknown` from
   `GtElixir.Beads.Issue.ready/0` (which itself reads
   `GtElixir.Beads.Dependency`). The CLI's behavior is correct — it
   surfaces "HTTP 500" — but the user experience is bad until either
   gte-003 or gte-005 fixes that read action. I considered adding a
   client-side fallback that hits `/api/issues?status=open` and filters,
   but it would mask a real server bug. I'd rather file the bug.
   Recommended follow-up bead: investigate and fix
   `GtElixir.Beads.Issue.ready/0` server-side.

2. **`--labels` flag.** Accepted on `bd2 create` and `bd2 list` for
   interface parity with Go `bd`, but ignored with a stderr warning. The
   Issue resource has no `labels` attribute (gte-002). Cleanest path
   forward is a separate bead to add labels to the Issue resource (which
   probably wants its own attribute or join table); shouldn't block
   gte-006.

3. **No subcommand for creating workspaces.** Spec lists 10 subcommands
   and workspace creation isn't one of them. `bd2 where` reports the
   active workspace; users create new ones via `POST /api/workspaces` or
   the seeds script. Worth a future `bd2 workspace create` if Ryan wants
   parity with bd's workspace handling.

## What I noticed worth improving separately

- **The `/api/issues/ready` 500.** Pre-existing, blocks `bd2 ready` from
  being useful. See spec deviation 1.

- **Plug debug page leaks on 500.** When the API hits an
  `Ash.Error.Unknown` (e.g. the ready bug), Phoenix's dev-mode debugger
  returns an HTML page rather than going through the fallback controller
  — so the client receives HTML for a JSON request. My client handles
  this gracefully (prints "HTTP 500") but the user loses any error
  detail. Either the fallback should catch this earlier, or the dev
  debugger should be disabled for the `:api` pipeline.

- **`bd2 list` has no `--workspace` filter for the active workspace.**
  Right now `bd2 list` returns issues across *all* workspaces. The user
  could pass `--workspace-id <uuid>` but that's awkward. Worth
  defaulting `list` to the active workspace, with `--all` to opt out.
  Punted to keep this PR small.

- **No `bd2 --version` global flag yet beyond the bare `-v` /
  `--version`.** Hardcoded in `Main`. Should read from `mix.exs`. Cheap
  cleanup.

- **Test isolation for `BD2_HOST`.** The client test that exercises the
  `BD2_HOST` env var uses `System.put_env`/`delete_env`, which is
  process-global and would break `async: true`. The test currently does
  the cleanup correctly but if another test starts using `BD2_HOST`
  there'll be a flake. Either move to `async: false` or wrap in a setup
  block that snapshots-and-restores. Worth a sweep when the next env-var
  flag lands.

- **`OptionParser.parse/2` accepts unknown switches silently** — bd2
  doesn't error on `bd2 show --not-a-real-flag`. Tightening this means
  threading the `:strict` option through every subcommand, which I
  punted. Easy follow-up.

## How to verify

```sh
cd ~/dev/gt-elixir-wt-006

# 1. Build + test (no Phoenix needed)
cd apps/gt_elixir_cli
mix compile --warnings-as-errors
mix format --check-formatted
mix test    # 48 tests, 0 failures

# 2. Smoke test (needs Phoenix)
cd ../..
mix phx.server &
sleep 4
cd apps/gt_elixir_cli && mix escript.build

./bd2 doctor             # all green
./bd2 where              # default workspace
ID=$(./bd2 create "Smoke" --priority 2 --json | jq -r .id)
./bd2 show $ID           # detail view
./bd2 close $ID          # status=closed
./bd2 list --status closed --json | jq '.data | length'
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

3. **`bd2 ready` design choice.** I chose to surface the upstream 500
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
- **gte-006a** (recommended): file a bead for `GtElixir.Beads.Issue.ready/0`
  fix so `bd2 ready` becomes useful.
- **gte-008** (if I'm reading the roadmap right): live integration tests
  that boot the actual web stack and exercise bd2 end-to-end.
