# arbiter

A local-first project coordination system. Track work as Directives
(beads), group them into Strike Forces (convoys), and dispatch Acolyte
(polecat) agents to work them — with a LiveView dashboard and a CLI
(`arb`) for interacting with everything.

## Prerequisites

- **Elixir 1.19+ / Erlang 28+** — [mise](https://mise.jdx.dev/) is the
  recommended way to install. With mise installed:

      mise install

  (The `.tool-versions` file in this repo pins the exact versions.)

- **Docker** — for the Postgres database.
  [Install Docker](https://docs.docker.com/get-docker/) if you don't have it.

## Install

```sh
# 1. Clone
git clone <repo-url> arbiter
cd arbiter

# 2. Start the database
docker compose up -d

# 3. Install dependencies, run migrations, seed the default workspace
mix setup

# 4. Build the arb CLI escript
cd apps/arbiter_cli && mix escript.build && cd ../..

# 5. Install arb on your PATH
mkdir -p ~/.local/bin
cp apps/arbiter_cli/arb ~/.local/bin/
```

If `~/.local/bin` isn't in your PATH yet, add this to your shell profile
(`.bashrc`, `.zshrc`, etc.) and restart your terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Re-run step 4 (and copy the binary again) any time you pull changes to
`apps/arbiter_cli`.

## Start the server

```sh
mix phx.server
```

The dashboard is at **http://127.0.0.1:4848**.

Keep this running in a terminal (or as a background service) — `arb`
talks to it over HTTP.

Or use the one-shot convenience:

```sh
arb start
```

`arb start` is a no-op if the stack is already up; otherwise it runs
`docker compose up -d` and launches `mix phx.server` detached, then
polls `arb doctor` until everything is green.

To have the stack come up automatically at boot (no manual `arb start`),
install it as a systemd service:

```sh
arb install-service          # user unit + loginctl enable-linger
arb install-service --system # system-wide unit (needs sudo)
```

This writes a unit whose `ExecStart` is `arb start`, enables it, and
prints how to check status/logs. `arb install-service --uninstall`
removes it again.

## Initialize your Admiral session

The Admiral is a dedicated Claude Code session that acts as your
coordinator. It has its own working directory with persistent memory and
a notes folder.

```sh
mkdir ~/admiral && cd ~/admiral
arb init         # initializes the current directory
```

Or pass a path to initialize elsewhere:

```sh
arb init ~/my-admiral
cd ~/my-admiral
```

Then open Claude Code:

```sh
claude
```

The Admiral will check whether the server is running, start it if
needed, orient itself with `arb prime`, and be ready to coordinate your
work.

## Adding Ships (projects)

A **Ship** (internally still called a "rig") is a local git repository
that Acolytes can work in. Add your projects via the dashboard
(Workspace → edit config), or in `config/dev.exs`:

```elixir
config :arbiter, :rig_paths, %{
  "my-project" => Path.expand("~/dev/my-project")
}
```

Restart the server after editing `dev.exs`.

## Quick reference

```
arb prime               # mission briefing — run at the start of any session
arb list                # list all Directives
arb ready               # Directives ready to be worked (deps closed)
arb show <id>           # detail on one Directive
arb create              # create a new Directive
arb sling <id> [ship]   # dispatch an Acolyte to work a Directive
arb polecat list        # list running Acolytes
arb doctor              # health-check the stack
arb start               # boot Postgres + Phoenix if down
arb install-service     # install a systemd unit so the stack starts at boot
```

All commands accept `--help` and `--json`. The CLI keeps the literal
verb names (`polecat`, `sling`, …) stable while prose and dashboard
output render the active workspace's vernacular (Acolyte, Strike Force,
etc. — see `apps/arbiter/lib/arbiter/vernacular.ex`).
