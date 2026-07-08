# Arbiter

**Arbiter** is an AI-driven issue tracker and autonomous coding agent harness. It coordinates work across your projects through a CLI (`arb`), MCP tools for a coordinator agent, and a LiveView dashboard. Tasks are tracked as **issues**, dispatched to **worker** agents for autonomous execution in isolated git worktrees, and merged through a **ReviewGate** and **merge queue** for code quality and safety.

## Prerequisites

- **Elixir 1.19+ / Erlang 28+** — [mise](https://mise.jdx.dev/) is the
  recommended way to install. With mise installed:

      mise install

  (The `.tool-versions` file in this repo pins the exact versions.)

Arbiter's datastore is **SQLite** — no database server or Docker is required.

## Install (development)

```sh
# 1. Clone
git clone <repo-url> arbiter
cd arbiter

# 2. Install dependencies, run migrations, seed the default workspace
mix setup

# 3. Build and install the arb CLI onto your PATH
arb install cli
```

`arb install cli` builds the CLI escript from `apps/arbiter_cli` and installs
it to `~/.local/bin/arb`. If `~/.local/bin` isn't in your PATH yet, add this
to your shell profile (`.bashrc`, `.zshrc`, etc.) and restart your terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Since `arb install cli` itself depends on `arb` already being on your PATH the
very first time, bootstrap it once by hand:

```sh
cd apps/arbiter_cli && mix escript.build && cd ../..
mkdir -p ~/.local/bin && cp apps/arbiter_cli/arb ~/.local/bin/
```

Re-run `arb install cli` any time you pull changes to `apps/arbiter_cli`.

## Architecture

**Workspaces** — isolated coordination scopes. A workspace holds a set of issues, dispatch policies, and tooling configuration. An installation can run multiple workspaces side by side, each with its own repos, tracker, and merge settings.

**Repos** — registered git repositories. Workers check out code on repos to work on issues.

**Issues** — tasks to be worked. Can be tracked in an external system (Jira, GitHub, Linear) or managed locally. Status flows from creation through ready → in_progress → done.

**Workers** — autonomous agents spawned via Claude Code (or future adapters) to work an issue. Each worker receives an issue, works it in an isolated git worktree, and reports completion with a PR or notes. Their full transcript is retained for audit and learning.

**ReviewGate** — optional quality checkpoint. A second Claude agent reviews the worker's work before merging. Can be disabled per-issue.

**Merge queue** — batches approved changes and applies them to the repo in sequence. Handles merge conflicts, CI status checks, and rollback on failure.

**PRPatrol** — polls open PRs per repo and dispatches follow-up workers when a review needs a response (changes requested, unresolved review threads, or failing required checks).

**Watchdog** — polls a merge request's fate for a worker parked at `:awaiting_review` and drives the worker to its terminal state (merged, closed/rejected, or auto-merged).

**Escalation mailbox** — the coordinator's inbox for anything that needs a human or coordinator ruling (e.g. a ReviewGate escalation, a worker failure). Read it via `arb message inbox` or the `inbox_check` / `notify_list` MCP tools.

**`/events`** — a server-push event stream (`GET /events`) for the coordinator: newline-delimited JSON, one event per line, for topics like `inbox`, `review_gate`, `worker_failed`, `worker_done`, and (opt-in) `task_state` / `external_review`.

## Coordinating via MCP

The primary integration path for a coordinator agent (e.g. a dedicated Claude Code session) is the `arbiter` MCP server, which exposes tools like `task_show`, `task_create`, `task_list`, `worker_dispatch`, `worker_resume`, `worker_review`, `worker_list`, `worker_log`, `inbox_check`, `message_send`, `notify_list`, `workspace_show`, `workspace_config_get/set`, `skill_list`/`skill_get`, `usage_summarize`, and more. See `apps/arbiter/lib/arbiter/mcp/catalog.ex` for the full, current catalog and which tier (worker vs. coordinator) can call each tool.

To mint a token for a coordinator to use:

```sh
arb mcp token mint --tier coordinator
```

## Quick-start

### 1. Start the server

```sh
arb server start
```

The dashboard is at **http://127.0.0.1:4848**.

### 2. Configure a workspace

Visit the dashboard's **Workspace** page and configure:
- **Repos** (projects to work in)
- Worker settings (Claude model, timeout, etc.)
- Optionally a **tracker** (Jira, GitHub, Linear) and merge strategy

Or edit `config/dev.exs` directly and restart the server, or use `arb config set`.

### 3. Dispatch your first issue

Create and dispatch an issue via the dashboard or CLI:

```sh
arb issue create "Fix typo in README"
arb issue dispatch <id> my-project
```

Watch the worker in the dashboard, or tail the transcript:

```sh
arb worker log <task-id>
```

Once complete, the merge queue picks it up (if configured) or you can merge manually via the dashboard.

### Running as a systemd service

To run Arbiter as a self-contained OTP release under a systemd user unit, install and enable it with:

```sh
arb install service
```

This writes `~/.config/systemd/user/arbiter.service` (`ExecStart=~/.arbiter/current/bin/arbiter start`), enables it via `loginctl enable-linger` for machine-boot startup, and starts the release. Manage it with `systemctl --user status arbiter.service` and view logs with `journalctl --user -u arbiter.service -f`. Pass `--system` to install a system-wide unit instead (needs root). Secrets and PATH configuration live in `~/.arbiter/arbiter.env`. Uninstall with `arb install service --uninstall`.

### Production deploys — OTP releases

Production runs are self-contained OTP releases unpacked under `~/.arbiter/releases/<tag>/`, with `~/.arbiter/current` symlinked atomically to the active one — no source checkout or Elixir/Mix toolchain needed on the box. Deploy a specific version (or `latest`) with:

```sh
arb server deploy --version v1.2.3
```

This downloads the release tarball + checksum from GitHub Releases (`ARB_RELEASE_REPO`), verifies the SHA-256, unpacks it, runs migrations, atomically swaps `current`, restarts the service, and health-checks it — auto-rolling back to the last-known-good release if it doesn't come back green. In a dev checkout with no `ARB_RELEASE_REPO` set, `arb server deploy` falls back to a `git pull --ff-only` + rebuild path instead.

### Remote `arb` — access Arbiter over VPN

By default, `arb` talks to a local server on `http://127.0.0.1:4848` (loopback). To point `arb` at a remote Arbiter server:

1. **Set `ARB_HOST`** to your server's URL over VPN:

   ```sh
   export ARB_HOST="http://arbiter.internal.example.com"
   # or export ARB_HOST="https://arbiter.example.com" for HTTPS
   ```

2. **Mint a token** on the server:

   ```sh
   arb mcp token mint --tier coordinator
   ```

3. **Export the token** on the client:

   ```sh
   export ARB_TOKEN="<token-from-step-2>"
   ```

4. **Verify the connection**:

   ```sh
   arb prime
   ```

- **Local loopback** (`ARB_HOST` unset or `http://127.0.0.1:4848`) requires no `ARB_TOKEN` — the server exempts localhost.
- **Remote access** requires both `ARB_HOST` and `ARB_TOKEN`.

### Encryption key (`ARBITER_CLOAK_KEY`) — required

Arbiter encrypts workspace secrets (tracker / merger credentials) at rest using
AES-256-GCM via [`ash_cloak`](https://hex.pm/packages/ash_cloak). **The server
refuses to start without an encryption key.** Generate a 32-byte Base64 key and
add it to your environment before deploying:

```sh
echo "ARBITER_CLOAK_KEY=$(openssl rand -base64 32)" >> ~/.arbiter/arbiter.env
# (for a non-service run, put it in the project-root .arbiter.env or export it)
```

`arb install service` forwards `ARBITER_CLOAK_KEY` from the installing shell
into `~/.arbiter/arbiter.env` automatically if it is set. Treat this key like a
database password: back it up and keep it stable — rotating it (re-encrypting
existing secrets) is a separate runbook and is not yet automated. Losing it
makes existing encrypted secrets unrecoverable.

### Storing tracker / merger credentials in the database

Instead of pointing `credentials_ref` at an environment variable
(`credentials_ref: "env:SHORTCUT_API_TOKEN"`), you can store the token directly
on the workspace, encrypted at rest, and reference it with a `secret:` ref. This
needs no server-side env var and no restart:

```sh
# 1. store the encrypted secret on the workspace
arb workspace secret set tracker_token sct_rw_...

# 2. point the tracker config at it
arb config set tracker.config.credentials_ref secret:tracker_token

# inspect / remove (values are never shown — only key names)
arb workspace secret ls
arb workspace secret rm tracker_token
```

Existing `env:` refs keep working unchanged, so you can migrate one workspace at
a time. Secret **values** are never returned by the API or CLI — only the key
names are listed.

## Initialize your coordinator session

A **coordinator** is a dedicated Claude Code session that directs work across
a workspace — creating and dispatching issues, reviewing worker output, and
resolving escalations — typically via the MCP tools above. It has its own
working directory with persistent memory and a notes folder.

```sh
mkdir ~/coordinator && cd ~/coordinator
arb init         # initializes the current directory
```

Or pass a path to initialize elsewhere:

```sh
arb init ~/my-coordinator
cd ~/my-coordinator
```

Then open Claude Code:

```sh
claude
```

The coordinator session will check whether the server is running, start it if
needed, orient itself with `arb prime`, and be ready to coordinate your work.

## Adding repos (projects)

A **repo** is a local git repository that workers check out and work in. Register your projects via the dashboard (Workspace → Repos), or directly in `config/dev.exs`:

```elixir
config :arbiter, :rig_paths, %{
  "my-project" => Path.expand("~/dev/my-project"),
  "another-project" => Path.expand("~/dev/another-project")
}
```

After editing `config/dev.exs`, restart the server for changes to take effect.

## CLI Reference

The CLI uses an `arb <resource> <verb>` grammar: `arb [resource] verb [args]`.
Run `arb help` (or `arb --help`) for the exhaustive, always-current usage text
(`apps/arbiter_cli/lib/arbiter_cli/main.ex`); the table below covers the
commands you'll reach for most.

### Key commands

| Command | Purpose |
|---------|---------|
| `arb prime` | Mission briefing — run at session start to check workspace status |
| `arb issue list` | List issues in the workspace |
| `arb issue show <id>` | View an issue's details and history |
| `arb issue create <title>` | Create a new issue |
| `arb issue dispatch <id> [repo]` | Dispatch a worker to work on an issue |
| `arb worker list` | List running and completed workers |
| `arb worker log <task-id>` | Read a worker's full transcript (durable) |
| `arb worker review <task-id>` | Dispatch a review-only worker against a task |
| `arb message inbox` | Read (and mark read) the coordinator's escalation mailbox |
| `arb server start` | Boot the stack (no-op if already up) |
| `arb server deploy [--version vX.Y.Z]` | Deploy an OTP release from GitHub Releases (auto-rollback on failure) |
| `arb server doctor` | Health-check the server and database |
| `arb config get/set [workspace]` | Read/edit workspace configuration (tracker, merger, etc.) |
| `arb mcp token mint --tier coordinator` | Mint an MCP token for a coordinator session |

All commands accept `--help` and `--json` for structured output. Pre-`<resource> <verb>`
flat commands from earlier CLI versions (`arb list`, `arb start`, `arb doctor`, …) still
run — they print a one-line note pointing at the new form. (`arb dispatch <id>` is a
permanent top-level shortcut for `arb issue dispatch <id>`, not a legacy alias.)
