# Arbiter

**Arbiter** is an AI-driven issue tracker and autonomous coding agent harness. It coordinates work across your projects through a CLI (`arb`) and a LiveView dashboard. Tasks are tracked as **Directives**, dispatched to **Acolyte** agents for autonomous execution, and merged through a **Review Gate** and **Merge Queue** for code quality and safety.

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

## Architecture

**Workspaces** — isolated coordination scopes. A workspace holds a set of Directives, dispatch policies, and tooling configuration. Each has its own CLI vernacular (naming convention for resources).

**Warships** — registered git repositories. Acolytes check out code on Warships to work on Directives.

**Directives** — tasks/issues to be worked. Can be tracked in an external system (Jira, GitHub, Linear) or managed locally. Status flows from creation through ready → in_progress → done.

**Acolytes** — autonomous worker agents spawned via Claude Code (or future adapters). Each Acolyte receives a Directive, works it in an isolated git worktree, and reports completion with a PR or notes. Their full transcript is retained for audit and learning.

**Review Gate** — optional quality checkpoint. A second Claude agent reviews the Acolyte's work before merging. Can be disabled per-Directive.

**Merge Queue** — batches approved changes and applies them to the Warship in sequence. Handles merge conflicts, CI status checks, and rollback on failure.

## Quick-start

### 1. Start the server

Run this once to get the stack up:

```sh
arb start
```

(Or manually: `docker compose up -d && mix phx.server`)

The dashboard is at **http://127.0.0.1:4848**.

### 2. Configure a workspace

Visit the dashboard's **Workspace** page and configure:
- **Warships** (repos to work in)
- **Acolyte** settings (Claude model, timeout, etc.)
- Optionally a **Tracker** (Jira, GitHub, Linear) and **Merger** strategy

Or edit `config/dev.exs` directly and restart the server.

### 3. Dispatch your first directive

Create a Directive via the dashboard or CLI:

```sh
arb issue create "Fix typo in README"
arb issue dispatch <id> my-project
```

Watch the Acolyte work in the dashboard, or tail the transcript:

```sh
arb worker log <worker-id>
```

Once complete, the Merge Queue picks it up (if configured) or you can merge manually via the dashboard.

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

### Manual server control

For manual control (useful in development), run the server components separately:

```sh
# Terminal 1: database
docker compose up

# Terminal 2: Phoenix server (in another tab)
mix phx.server
```

To start both in one command:

```sh
docker compose up -d && mix phx.server
```

#### Systemd service (optional)

To have the stack start automatically at boot:

```sh
arb install-service          # user unit + loginctl enable-linger
arb install-service --system # system-wide unit (needs sudo)
```

Uninstall with `arb install-service --uninstall`.

## Adding Warships (projects)

A **Warship** is a local git repository that Acolytes check out and work in. Register your projects via the dashboard (Workspace → Warships), or directly in `config/dev.exs`:

```elixir
config :arbiter, :rig_paths, %{
  "my-project" => Path.expand("~/dev/my-project"),
  "another-project" => Path.expand("~/dev/another-project")
}
```

After editing `config/dev.exs`, restart the server for changes to take effect.

## CLI Reference

The CLI uses an `arb <resource> <verb>` grammar: `arb [resource] verb [args]`.

### Key commands

| Command | Purpose |
|---------|---------|
| `arb prime` | Mission briefing — run at session start to check workspace status |
| `arb issue list` | List all Directives in the workspace |
| `arb issue show <id>` | View a Directive's details and history |
| `arb issue create <title>` | Create a new Directive |
| `arb issue dispatch <id> [warship]` | Dispatch an Acolyte to work on a Directive |
| `arb worker list` | List running and completed Acolytes |
| `arb worker log <id>` | Read an Acolyte's full transcript (durable) |
| `arb server start` | Boot the stack (no-op if already up) |
| `arb server doctor` | Health-check the Postgres DB and server |
| `arb config [workspace]` | Edit workspace configuration (tracker, merger, vernacular) |

All commands accept `--help` and `--json` for structured output.

### Vernacular aliases

The active workspace's vernacular maps a themed label onto each canonical
resource, and the themed label resolves automatically. The default (Sith)
vocabulary gives:

| canonical  | default label | example                                        |
|------------|---------------|------------------------------------------------|
| `worker`   | `polecat`     | `arb polecat list` → `arb worker list`         |
| `issue`    | `task`        | `arb task show <id>` → `arb issue show <id>`    |
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
