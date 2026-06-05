# SQLite Migration: Dropping Postgres

**Bead:** bd-tbslcb  
**Date:** 2026-06-05

## Decision

Replace Postgres (ash_postgres + postgrex) with SQLite (ash_sqlite + ecto_sqlite3). Arbiter is a
single-node orchestration service with modest write throughput; SQLite's serialized writes and
embedded deployment model are a better fit than a separate Postgres process.

## Dependency changes

| Removed | Added |
|---|---|
| `ash_postgres ~> 2.0` | `ash_sqlite ~> 0.2` |
| `postgrex >= 0.0.0` | `ecto_sqlite3 ~> 0.17` |

`ash_sql` remains (shared SQL layer used by both adapters). `ash_paper_trail` continues to work
unchanged.

## Data layer swap

All 10 Ash resources (settings, issue, message, workspace, convoy_membership, dependency, convoy,
usage/event, polecats/run, workflows/machine_state) changed from:

```elixir
data_layer: AshPostgres.DataLayer
postgres do ... end
```

to:

```elixir
data_layer: AshSqlite.DataLayer
sqlite do ... end
```

`Arbiter.Repo` changed from `use AshPostgres.Repo` to `use AshSqlite.Repo`.

## Concurrency: WAL + busy_timeout

SQLite is configured with `journal_mode: :wal` and `busy_timeout: 5000` in all environments. WAL
allows concurrent reads while a write is in progress. `busy_timeout` prevents `SQLITE_BUSY` errors
when two writers contend; ecto_sqlite3 retries up to 5 s before propagating an error.

## Single-instance guard

The original `Arbiter.SingleInstance` used `pg_try_advisory_lock` (a Postgres session-level lock)
to prevent two concurrent boots from both running orphan-sweep reconciliation. This was replaced
with a two-layer guard:

1. **In-process (ETS):** `:ets.insert_new/2` prevents two GenServers in the same Erlang VM from
   both claiming the lock. Covers duplicate `iex -S mix` and test scenarios.
2. **Cross-process (PID file):** a file in the data directory (`~/.arbiter/arbiter.pid`) stores the
   OS PID of the holder. On acquire the guard checks whether the recorded PID is still alive via
   `kill -0`; a stale file from a crash is overwritten. The file is removed on clean shutdown via
   `terminate/2`.

The `:lock_key` integer option (used in tests) maps to `/tmp/arbiter_lock_{key}.pid`, preserving
the test API.

## Aggregate limitation in ash_sqlite 0.2.x

`ash_sqlite` 0.2.x returns `false` for `can?(_, {:aggregate, _type})`, so inline `aggregates do`
blocks on resources are not supported. The Convoy resource used two aggregates (`total_issues`,
`closed_issues`) over the `many_to_many :issues` relationship.

These were replaced with module-based calculations in `Arbiter.Beads.Convoy.Calcs`. The
calculations batch-load `ConvoyMembership` rows filtered to the current convoy set, then count
in Elixir — no N+1 queries. `Ash.count!` with `{:query_aggregate, :count}` still works; only
inline resource aggregates are restricted.

## Config changes

### config/config.exs
- Removed `known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]` from ash config
- Spark formatter `section_order` changed `:postgres` → `:sqlite`
- Added `config :exqlite, force_build: true` (required on RHEL 8 / glibc < 2.33; the precompiled
  NIF requires glibc 2.33)

### config/dev.exs
```elixir
config :arbiter, Arbiter.Repo,
  database: Path.expand("~/dev/arbiter_dev.sqlite3"),
  journal_mode: :wal,
  busy_timeout: 5000,
  pool_size: 5
```

### config/test.exs
```elixir
config :arbiter, Arbiter.Repo,
  database: Path.join(System.tmp_dir!(), "arbiter_test#{System.get_env("MIX_TEST_PARTITION", "")}.sqlite3"),
  journal_mode: :wal,
  busy_timeout: 5000,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
```

### config/runtime.exs
Removed the mandatory `DATABASE_URL` raise. Now reads `DATABASE_PATH` env var, defaulting to
`~/.arbiter/arbiter.sqlite3`.

## Migrations

Old Postgres migrations deleted from `apps/arbiter/priv/repo/migrations/`. A single fresh
migration `20260605220214_initial_sqlite.exs` was generated via `mix ash_sqlite.generate_migrations`
covering all resources. Resource snapshots regenerated accordingly.

## Known SQLite differences

- **UUID version enforcement:** Postgres enforced UUIDv7 format at the database level via the native
  UUID type. SQLite stores UUIDs as text without version validation; rows with v4 UUIDs injected via
  `Repo.insert_all` are readable by Ash. Ash still validates UUIDs on write through normal actions.
  The `DependencyTest` "v4-id row rejected on read" test is skipped with a documenting comment.

- **No advisory locks:** replaced by ETS + PID file (described above).

- **Array columns:** `{:array, :string}` attributes map to `{:array, :text}` in SQLite migrations,
  which is correct — SQLite stores arrays as JSON text arrays.

## Deployment

1. Stop arbiter service
2. Ensure `DATABASE_PATH` is set (or rely on default `~/.arbiter/arbiter.sqlite3`)
3. Run `mix arbiter.migrate` (applies the single initial migration)
4. Start arbiter service

No data migration from Postgres is provided. This is a greenfield SQLite deployment; if a Postgres
database needs to be migrated, use `pgloader` or a custom script to export/import via CSV.
