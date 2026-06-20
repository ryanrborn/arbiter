# Postgres setup for local development

arbiter uses Postgres (via ash_postgres) for the task store, audit log, workspace config, and everything else.

## Quick start

```sh
cd ~/dev/arbiter
docker compose up -d
```

This starts a Postgres 17 container bound to `127.0.0.1:5432` with:

| Setting | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `5432` |
| User | `arbiter` |
| Password | `arbiter_dev_password` |
| Default DB | `arbiter_dev` |
| Data volume | `arbiter-pgdata` (named, persistent across container restarts) |

Phoenix `config/dev.exs` connects with these credentials. `config/test.exs` uses the same instance but creates / drops `arbiter_test` on each run.

## Lifecycle

```sh
docker compose up -d        # start in background
docker compose logs -f      # tail logs
docker compose stop         # stop without removing data
docker compose down         # stop and remove containers (keeps volume)
docker compose down -v      # stop and WIPE the data volume
```

## Connect with psql

```sh
docker compose exec postgres psql -U arbiter -d arbiter_dev
```

Or from the host (if psql is installed):

```sh
PGPASSWORD=arbiter_dev_password psql -h 127.0.0.1 -U arbiter arbiter_dev
```

## Why Postgres (not SQLite)

- ash_postgres is at v2.9+ (mature). ash_sqlite is at v0.2.17 (still 0.x, missing Aggregates).
- Our `Convoy.progress` derived field is a textbook Aggregate.
- Future Oban + LISTEN/NOTIFY clustering work better on Postgres.
- Local Postgres via Docker is barely more friction than a SQLite file.

See `docs/decision-doc.md` decision 1 (Postgres + Quantum) for the full rationale.
