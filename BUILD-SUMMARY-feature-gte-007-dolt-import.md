# gte-007 — Dolt-to-Postgres import script

Task: gte-007
Branch: `feature/gte-007-dolt-import`

## What

Mix task `arbiter.import_from_dolt` that reads issues + dependencies from one
or more existing gas-town Dolt DBs and inserts them into the arbiter Postgres
store via `Ecto.Repo.insert_all`. Idempotent on re-run.

```bash
mix arbiter.import_from_dolt \
    --hq-path /home/rborn/dev/gt/.dolt-data/hq \
    --server-path /home/rborn/dev/gt/.dolt-data/server
```

Per source the task:

1. Reads `SELECT * FROM issues` via `dolt sql -r json`.
2. Finds or creates a `Workspace` with the source name (`hq`, `server`) and a
   well-known prefix (`hq`, `vs`).
3. Bulk-inserts issues via `Ecto.Repo.insert_all`, bypassing Ash's `GenerateId`
   so original Dolt IDs are preserved. `ON CONFLICT (id) DO NOTHING`.
4. Reads `SELECT * FROM dependencies`, filters out edges that reference issues
   not present in Postgres (cross-rig orphans), and bulk-inserts the rest with
   `ON CONFLICT (from_issue_id, to_issue_id, type) DO NOTHING`.

## Files

- `apps/arbiter/lib/mix/tasks/arbiter.import_from_dolt.ex` — mix task,
  Dolt I/O, workspace lookup, bulk inserts.
- `apps/arbiter/lib/arbiter/tasks/dolt_import/mapper.ex` — pure field
  mappers, kept separate so they can be unit-tested without a live Dolt DB.
  Functions: `map_status/1`, `map_issue_type/1`, `parse_priority/1`,
  `parse_external_ref/1`, `map_dep_type/1`, `parse_dt/1`, `compose_description/1`,
  `derive_prefix/1`, `nonempty/1`.
- `apps/arbiter/test/arbiter/tasks/dolt_import/mapper_test.exs` — 30 unit
  tests covering every mapper function and its edge cases.

## Verified end-to-end

Against the current hq + server Dolt DBs:

```
→ Importing from hq
  workspace hq (prefix=hq)
  ✓ inserted 117 new issues
  ✓ inserted 48 new dependencies (18 cross-rig orphans filtered)

→ Importing from server
  workspace server (prefix=vs)
  ✓ inserted 23 new issues
  ✓ inserted 14 new dependencies (8 cross-rig orphans filtered)
```

Re-running is a no-op (all rows already present).

## Things the reviewer should pay attention to

### 1. The cross-rig FK filter

Dolt's `dependencies` table sometimes references tasks that don't live in the
same Dolt DB (e.g. server has `vs-e5m → vs-wisp-ddn1` where the wisp task
exists transiently in the mayor's runtime but never made it back to the server
Dolt). Postgres has a `FOREIGN KEY` on both `from_issue_id` and `to_issue_id`,
so these orphan refs would crash the entire batch insert.

The fix (in `bulk_insert_dependencies/1`):

```elixir
known_ids =
  Arbiter.Repo.query!("SELECT id FROM issues", [])
  |> Map.get(:rows)
  |> Enum.map(&hd/1)
  |> MapSet.new()
```

Edges where either endpoint isn't in `known_ids` are dropped. Logged at the
batch level only (`14 new deps, 8 already present` — orphans are silently
filtered). If we want explicit per-row logging later, that's a one-line
addition.

**Subtle bug I hit during build**: `in/2` does **not** use `MapSet.member?/2`
under the hood. `row["id"] not in mapset` always evaluates against MapSet as
a struct, not its members. The fix is `not MapSet.member?(known_ids, ...)`
spelled out. Saved here so the next person doesn't repeat it.

### 2. Hardcoded `@known_prefixes` map

```elixir
@known_prefixes %{
  "hq" => "hq", "server" => "vs", "access_control" => "ac",
  "admin_server" => "ad", "auth_server" => "as",
  "verus_client" => "vc", "voice_biometrics" => "vb"
}
```

Falls back to `Mapper.derive_prefix/1` for unknown sources (reads prefix from
the first row's ID). Reason for hardcoding: the hq Dolt's `issues` table
contains tasks from other rigs (mail bodies and escalations are stored as
tasks), so `derive_prefix` would pick whatever's first by insertion order —
returned `"ac"` during testing. Hardcoding by source-name is the safer call.

### 3. `Ecto.insert_all` raw-type quirks

- Postgres `varchar` columns need binaries, not atoms — wrapped enum values
  with `Atom.to_string/1` (`status`, `issue_type`, `tracker_type`, dep `type`).
- Postgres `uuid` columns need 16-byte binaries — used `Ecto.UUID.dump!/1` for
  `workspace_id` and `Ecto.UUID.bingenerate/0` for new dep PKs.

Both bit me. If `bulk_insert_*` ever grows another column, watch the types.

### 4. Bypasses Ash and paper_trail

This task writes directly to the `issues` and `dependencies` tables via Ecto.
Consequences:

- No `GenerateId` change runs → original Dolt IDs preserved (the whole point).
- No `InheritTrackerType` change runs → we explicitly parse `external_ref` and
  set `tracker_type` from that.
- No paper_trail versions are written → these are imports, not edits. If we
  want a synthetic "imported" version row per task later, that's a follow-up.
- No `GuardStatus` enforcement → fine, imports can land in any status.

### 5. Issue-set snapshot for filter

`known_ids` is read once at the start of `bulk_insert_dependencies/1`, after
that batch's issues are already inserted. So within a single source-import,
deps can reference issues just inserted from that same source. **Across
sources** (running hq then server), the server filter sees both hq + server
issue IDs and correctly accepts cross-workspace deps (e.g. an hq task blocked
by a server task).

This is the right semantics — cross-workspace deps are real, cross-orphan deps
are not.

## Test results

```
102 tests, 0 failures   # arbiter (72 pre-existing + 30 new Mapper tests)
5 tests, 0 failures     # arbiter_web (unchanged)
```

`mix compile --warnings-as-errors` clean. `mix format --check-formatted` clean.

## Follow-ups (not in this PR)

- The mapper hardcodes `@valid_dep_types` rather than introspecting
  `Dependency.dep_types/0` because the Dependency module didn't expose one at
  build time. If we expose it later, swap to the introspection.
- No live integration test that hits a real Dolt DB; the mapper unit tests
  cover field transforms and the mix task is verified manually. Adding a
  fixture-based integration test would require shipping a tiny Dolt repo or
  mocking `System.cmd("dolt", ...)`.
