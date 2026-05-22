# gt-elixir

A local-first project coordination system. Track work as beads, group them
into convoys, and dispatch polecat agents to work them — with a LiveView
dashboard and a CLI (`bd2`) for interacting with everything.

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
git clone <repo-url> gt-elixir
cd gt-elixir

# 2. Start the database
docker compose up -d

# 3. Install dependencies, run migrations, seed the default workspace
mix setup

# 4. Build and install the bd2 CLI
mix gt_elixir.install
```

`mix gt_elixir.install` places `bd2` in `~/.local/bin/`. If that directory
isn't in your PATH yet, add this to your shell profile (`.bashrc`, `.zshrc`,
etc.) and restart your terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Start the server

```sh
mix phx.server
```

The dashboard is at **http://127.0.0.1:4848**.

Keep this running in a terminal (or as a background service) — `bd2` talks
to it over HTTP.

## Initialize your Mayor session

The Mayor is a dedicated Claude Code session that acts as your coordinator.
It has its own working directory with persistent memory and a notes folder.

```sh
mkdir ~/mayor && cd ~/mayor
bd2 init         # initializes the current directory
```

Or pass a path to initialize elsewhere:

```sh
bd2 init ~/my-mayor
cd ~/my-mayor
```

Then open Claude Code:

```sh
claude
```

The Mayor will check whether the server is running, start it if needed,
orient itself with `bd2 prime`, and be ready to coordinate your work.

## Adding rigs (projects)

A **rig** is a local git repository that polecats can work in. Add your
projects via the dashboard (Workspace → edit config), or in `config/dev.exs`:

```elixir
config :gt_elixir, :rig_paths, %{
  "my-project" => Path.expand("~/dev/my-project")
}
```

Restart the server after editing `dev.exs`.

## Quick reference

```
bd2 prime               # mission briefing — run at the start of any session
bd2 list                # list all beads
bd2 ready               # beads ready to be worked (deps closed)
bd2 show <id>           # detail on one bead
bd2 create              # create a new bead
bd2 sling <id> [rig]    # dispatch a polecat to work a bead
bd2 polecat list        # list running polecats
```

All commands accept `--help` and `--json`.
