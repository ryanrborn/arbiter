# Build summary: feature/gte-001-umbrella-scaffold (v2)

**Task:** gte-001
**Builder:** Mayor (interactive session, 2026-05-19)
**Branch:** feature/gte-001-umbrella-scaffold (reset from v1)
**Commit:** eac3761

This **replaces** v1 (commits 792d022 + 3041b00 from 2026-05-18 overnight) which was reset because:
- It missed the asset pipeline (Tailwind v4 + DaisyUI + heroicons + esbuild) that `mix phx.new` ships by default
- It used `ash_sqlite` (still 0.x, missing Aggregates); switched to `ash_postgres` per decision 1
- It used hand-rolled umbrella naming (gt_core/gt_web/gt_cli); switched to Phoenix convention (arbiter/arbiter_web/arbiter_cli) per locked naming decision

## How it was generated

The intended path was `mix igniter.new --with=phx.new --install ash,...`, but Igniter rejects umbrella projects with a clear error:

> igniter.new is not currently compatible with umbrella applications.
> If you are sure that you want to use umbrella applications (there are plenty of good reasons), please generate the application using `mix phx.new`, and then run installers from individual applications.

Actual command sequence:

```sh
mix phx.new arbiter --umbrella --no-mailer
cd arbiter_umbrella/apps/arbiter
mix igniter.install ash ash_postgres ash_paper_trail ash_phoenix --yes
cd ../
mix new arbiter_cli --module ArbiterCli --app arbiter_cli
# Move umbrella contents to ~/dev/arbiter/
# Configure Postgres credentials in config/dev.exs + config/test.exs
# Add quantum + req deps to apps/arbiter/mix.exs
```

## What's in the repo

```
arbiter/
├── apps/
│   ├── arbiter/             # Ash domain (Repo, Ash + ash_postgres + ash_paper_trail wired)
│   │   ├── lib/arbiter/
│   │   │   ├── application.ex
│   │   │   └── repo.ex
│   │   └── priv/repo/migrations/20260519183245_initialize_extensions_1.exs
│   ├── arbiter_web/         # Phoenix + LiveView + Tailwind v4 + DaisyUI 5 + heroicons + esbuild
│   │   ├── assets/
│   │   │   ├── css/app.css    # tailwind 4 + daisyui (light + dark themes)
│   │   │   ├── js/app.js
│   │   │   └── vendor/        # daisyui.js, daisyui-theme.js, heroicons.js
│   │   ├── lib/arbiter_web/
│   │   │   ├── components/    # CoreComponents, layouts (root.html.heex, app.html.heex)
│   │   │   ├── controllers/   # PageController scaffold
│   │   │   ├── endpoint.ex, router.ex, telemetry.ex
│   │   ├── priv/static/       # favicon, images/logo.svg, robots.txt
│   │   └── test/
│   └── arbiter_cli/         # escript scaffold (commands land in gte-006)
├── compose.yml                # Postgres 17-alpine, healthcheck, named volume
├── config/
│   ├── config.exs, dev.exs, test.exs, prod.exs, runtime.exs
├── docs/
│   ├── decision-doc.md, postgres-setup.md
├── reviews/                   # (empty, awaiting first peer-review file)
├── AGENTS.md                  # Phoenix-generated; useful conventions for our polecats
├── MORNING-BRIEF.md, REVIEW-PROCESS.md, README.md
├── mix.exs, mix.lock
└── .formatter.exs, .gitignore
```

## Acceptance criteria (from task gte-001)

- [x] `docker compose up -d` starts Postgres healthy. Verified: `pg_isready` returns "accepting connections", `SELECT version()` returns "PostgreSQL 17.10".
- [x] `mix compile` clean. All 3 apps compile without errors.
- [x] `mix test` green. Counts: 1 doctest + 1 test for arbiter_cli; 0 tests for arbiter (no resources yet — that's gte-002); 5 tests for arbiter_web (Phoenix-generated defaults).
- [x] `mix phx.server` starts; `GET /` returns HTTP 200 with the Phoenix landing page rendered. DaisyUI classes (`toast`, `alert`, `alert-error`) and heroicons (`hero-exclamation-circle`, `hero-arrow-path`) confirmed in the rendered HTML.
- [x] Repo connects to Postgres in dev. Verified by `mix ecto.create` succeeding and the extension migration running.
- [x] Ash domain registered in supervision tree (Repo + Ash deps loaded; no `Ash.Domain` yet but the infrastructure is in place for gte-002).
- [x] AGENTS.md committed (Phoenix-generated; has useful conventions).

## What I punted on (with reasons)

1. **No Ash domain module yet.** `Ash.Domain` registration with resources is gte-002's scope (Issue resource). The `config :arbiter, ash_domains: []` line in config.exs is the placeholder.
2. **No Quantum config.** Added to deps but no scheduler configured. First scheduled job lands in gte-022 (PR patrol watcher).
3. **No CLI commands.** `arbiter_cli` is a vanilla `mix new` scaffold. Commands (`arb show / create / close / etc.`) land in gte-006.
4. **No DNS cluster config.** Phoenix-generated app includes `dns_cluster` dep but unconfigured. Fine for local-only dev.
5. **Watchman not installed.** Phoenix's file watcher logs `sh: watchman: command not found` on startup. Non-fatal — Phoenix falls back to polling. Install watchman later if dev reload feels sluggish.

## What I noticed worth improving separately

- **AGENTS.md is 22K and Phoenix-flavored.** It's useful but generic. May want to fork it into a project-specific `AGENTS.md` that points at our `docs/decision-doc.md` + `REVIEW-PROCESS.md`. Tracking as a thought; not a task yet.
- **Phoenix 1.8.3 vs 1.8.7.** Phoenix installer recommends updating: `mix local.phx`. Doing this now would regenerate phx.new templates, but our scaffold is already committed. Defer; upgrade in a follow-up.
- **`ash_phoenix` 2.0 is installed but we haven't used it.** It'll power LiveView form integration in gte-024 (dashboard).
- **No `.iex.exs` aliases.** Helpful for iex sessions. Trivial follow-up.

## How to verify

```sh
cd ~/dev/arbiter
git checkout feature/gte-001-umbrella-scaffold
docker compose up -d                              # Postgres
mix deps.get                                      # ~30s, lots of Ash deps
mix compile --warnings-as-errors                  # clean
MIX_ENV=test mix ecto.create                      # create test DB
MIX_ENV=test mix ecto.migrate                     # apply extension migration
mix test                                          # all green
mix phx.server &                                  # start in background
sleep 10                                          # give bandit a moment
curl -s -I http://127.0.0.1:4000/                 # expect HTTP 200
curl -s http://127.0.0.1:4000/ | grep -i daisy    # expect daisyUI version comment
kill %1                                           # stop
docker compose stop                               # stop Postgres (optional)
```

Expected: clean compile, all tests pass, Phoenix endpoint serves the default landing page with DaisyUI styling visible.

## Verdict requested

This task is complete per acceptance. Ready to merge to main:

```sh
git checkout main
git merge --squash --ff-only feature/gte-001-umbrella-scaffold
git commit  # use the existing commit message
```

After merge:
1. Close gte-001 in bd: `bd close gte-001 --reason "PR-like merge feature/gte-001 → main on 2026-05-19 (commit XXX)"`
2. Begin gte-P1 (Workspace resource) — it's unblocked now and gte-002 depends on it

Reviewer should sanity-check:
- mix.exs / mix.lock dep versions are reasonable
- config/dev.exs + config/test.exs Postgres credentials match compose.yml
- AGENTS.md is generic enough or needs tailoring
- The umbrella's auto-generated AGENTS.md is committed (Phoenix's convention for hint files agents can read)
- No stray secrets or hardcoded values that shouldn't be in version control
