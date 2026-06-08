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

The CLI uses an `arb <resource> <verb>` grammar. The resources are neutral
base terms — `issue`, `worker`, `batch`, `repo` — and themed vocabularies
(the Sith "polecat", "bead", "convoy", "warship", "sling", …) layer on top as
aliases.

```
arb prime                    # mission briefing — run at the start of a session
arb issue list               # list all issues
arb issue ready              # issues ready to be worked (deps closed)
arb issue show <id>          # detail on one issue
arb issue create <title>     # create a new issue
arb issue dispatch <id> [rig]# dispatch a worker to an issue
arb worker list              # list running workers
arb worker log <id>          # full durable transcript of a worker's run
arb batch list               # list batches in the active workspace
arb repo list                # registered repos (rigs)
arb workspace list           # configured workspaces
arb server doctor            # health-check the stack
arb server start             # boot SQLite-backed Phoenix if down
arb server deploy            # pull main → migrate → rebuild CLI → restart
arb install service          # systemd unit so the stack starts at boot
```

All commands accept `--help` and `--json`.

### Vernacular aliases

The active workspace's vernacular maps a themed label onto each canonical
resource, and the themed label resolves automatically. The default (Sith)
vocabulary gives:

| canonical  | default label | example                                        |
|------------|---------------|------------------------------------------------|
| `worker`   | `polecat`     | `arb polecat list` → `arb worker list`         |
| `issue`    | `bead`        | `arb bead show <id>` → `arb issue show <id>`    |
| `batch`    | `convoy`      | `arb convoy create …` → `arb batch create …`    |
| `repo`     | `warship`     | `arb warship list` → `arb repo list`            |
| `dispatch` | `sling`       | `arb sling <id>` → `arb issue dispatch <id>`    |

Pre-`<resource> <verb>` flat commands (`arb list`, `arb sling`, `arb update`,
…) still run — they print a one-line note pointing at the new form.

#### The `sith` preset

The full Sith lexicon is shipped as a named preset for prose and dashboards.
Apply it to the global vernacular (`PUT /api/settings/vernacular`, or the
dashboard's vernacular editor) to theme everything on top of the resource
aliases above:

```json
{
  "coordinator": "Admiral",    "worker": "Acolyte",
  "issue": "Directive",        "batch": "Strike Force",
  "repo": "Warship",           "dispatch": "Sling",
  "merge_queue": "Reclamation","monitor": "Inquisitor",
  "watchdog": "Grand Moff",    "epic": "Campaign"
}
```

Any installation can opt into its own lexicon the same way; the canonical
resource names never change. See `arb help vernacular` and
`apps/arbiter/lib/arbiter/vernacular.ex`.
