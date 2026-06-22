# Arbiter.MCP — a single MCP server for agent sessions — design spec

**Status:** design proposal (this is the spike deliverable for #254; not yet
approved)
**Date:** 2026-06-15
**Task:** bd-b2eqn5 · **Tracker:** github:254
**Author:** worker
**Builds on:** the pluggable agent harness (`docs/agent-harness-design.md`,
bd-c6xf18) and worker security (`docs/worker-security.md`, bd-9u10op) — the
MCP work reuses both seams.

## TL;DR

Stand up **`Arbiter.MCP`**, a single in-process Model Context Protocol server
that exposes Arbiter's domain operations (tasks, convoys, dependencies,
messages, workers, workspace) as schema-backed MCP tools, and connect agent
sessions to it. Capability is a **scope token** presented at connection time,
not a code fork. This replaces the model's current route back into Arbiter —
constructing `arb …` CLI invocations and parsing `--json` — with validated tool
calls and structured returns, and it is agent-agnostic because Claude Code,
Gemini CLI, and Codex all speak MCP.

Two recommendations that diverge from the issue text, both grounded in what the
codebase actually is today:

1. **Transport: Streamable HTTP, not "HTTP+SSE".** The issue says "HTTP/SSE
   transport". That two-endpoint transport was **deprecated** in MCP spec
   2025-03-26 and replaced by **Streamable HTTP** (a single endpoint that
   serves POST and GET, upgrading to SSE only for long-running calls). Build on
   Streamable HTTP; it is what all three target CLIs negotiate today.

2. **Scope tiers: `worker` and `coordinator`, not "worker and Mayor".** There
   is **no Mayor agent** in Arbiter today. The broad-capability client today is
   the **human operator** driving `arb` + the LiveView dashboard, plus internal
   GenServers (merge queue / watchdog, review gate). The spec keeps the two-tier
   capability model the issue asks for, but names the broad tier `coordinator`
   and is honest that its first consumer is the operator's own tooling; a future
   autonomous coordinator ("Mayor") would present the same token.

**Phase 1** ships read tools over Streamable HTTP behind two scope tiers, wired
to **Claude Code** via a per-spawn `.mcp.json`. **Phase 2** adds mutating tools
behind the `coordinator` tier with a dispatch-recursion guardrail. **Phase 3** adds
the Gemini and Codex config adapters.

## 1. Motivation, corrected to today's system

The issue's framing is GT-era. Two corrections matter for the design:

- **The current structured route is the `arb` CLI, not `bd2`.** A worker's only
  structured path back into Arbiter today is shelling out to the **`arb`
  escript**, which talks to the Phoenix REST API at `http://127.0.0.1:4848`
  (`apps/arbiter_cli/lib/arbiter_cli/client.ex`, base URL + `ARB_HOST`). The
  work prompt literally instructs the agent to run `arb inbox <task>`,
  `arb message <task> <text>`, and `arb issue update <task> --qa-notes …`
  (`apps/arbiter/lib/arbiter/worker/dispatch.ex`, `base_work_prompt/1`). The model
  constructs those argv strings and parses `--json`; the tool surface is
  discoverable only via `--help`. (`bd2` in this repo is just a test-seam prefix
  for process-dictionary keys — `:bd2_req_options` etc. — not a route.)

- **There is no Mayor session.** No agent process mutates state "all session
  long". Coordination is operator-driven (`arb` + dashboard) plus internal
  GenServers. So the broad-scope MCP client is, at first, the operator's own
  tooling — not an autonomous agent.

An MCP server fixes the agent-facing half at both tiers:

- **Workers** get a scoped, agent-native way to read their own task, check
  their mailbox, report progress, and write completion notes — from inside the
  agent loop, as typed tool calls instead of stringly-typed CLI guessing.
- **Coordinator-scope clients** (operator tooling now; a Mayor agent later) get
  validated `task_create` / `worker_dispatch` / convoy mutations with structured
  returns instead of CLI argv.

Because MCP is the write-once/use-across-agents abstraction, the tool
definitions are written **once** and agent type becomes a per-session config
detail — the same shape as the multi-adapter pattern already in `Trackers`,
`Mergers`, and `Agents`.

## 2. Architecture: one server, in-process with the domain

`Arbiter.MCP` is a single Streamable-HTTP MCP server hosted **inside the BEAM**,
mounted on the existing Phoenix endpoint in `arbiter_web` (Bandit, port 4848).
Because it runs in the same VM as the Ash domain, **tool handlers call Ash
directly** — exactly the path the REST controllers already take
(`Ash.read/2`, `Ash.create/2`, `Ash.update/3`, e.g.
`apps/arbiter_web/lib/arbiter_web/controllers/api/issue_controller.ex`). There
is no internal HTTP hop and no second source of truth.

```
   agent session (Claude Code / Gemini / Codex)
        │  MCP over Streamable HTTP  (POST/GET /mcp, Bearer <scope-token>)
        ▼
   Phoenix endpoint :4848  (Bandit)
        │
   ┌────────────────────────────────────────────┐
   │ Arbiter.MCP                                 │
   │  • transport plug (Streamable HTTP)         │
   │  • Arbiter.MCP.Scope  — token → claims      │  ← enforcement point
   │  • Arbiter.MCP.Tools.* — one module/tool    │
   └───────────────┬────────────────────────────┘
                   │ Ash.read/create/update (in-process)
                   ▼
   Arbiter.Tasks / Messages / Workers / Usage   (Ash domains)
```

### 2.1 Transport: Streamable HTTP

A single MCP endpoint (say `POST|GET /mcp`) under the existing `/api`-style
scope in `apps/arbiter_web/lib/arbiter_web/router.ex`. Clients POST JSON-RPC
2.0; the server returns a single JSON body for fast calls and upgrades to SSE
only for long ones. This works behind the load balancer / reverse proxy an
operator may already front :4848 with, and avoids spawning a fresh stdio MCP
server per session per agent type. The legacy two-endpoint HTTP+SSE transport is
deprecated upstream; we do not implement it.

### 2.2 Build vs. buy the protocol layer

No MCP dependency is present today (`mix.lock` has no `hermes`/`anubis`/`mcp`;
`phoenix 1.8.7`, `plug 1.19.2`, `bandit 1.11.1`, `jason` are available). Two
options:

| Option | What it is | Trade-off |
|---|---|---|
| **`anubis_mcp`** (recommended) | Elixir-native MCP SDK (the maintained fork of `hermes_mcp`), Plug/Phoenix integration, `streamable_http` transport, component-based tool registration | We own the JSON-RPC framing decisions to a config layer, not hand-written code; small external dep we don't control |
| Hand-rolled Plug | A Plug that parses JSON-RPC 2.0, dispatches `tools/list` + `tools/call`, frames SSE | Zero new deps; but we re-implement protocol plumbing (initialize handshake, capability negotiation, SSE framing, error envelopes) that a library already gets right |

**Recommendation: adopt `anubis_mcp`** and keep our code to (a) the tool
modules, (b) the scope plug, (c) the per-agent config adapter. Validate it
against Claude Code's `initialize` handshake on a spike before committing; fall
back to a hand-rolled Plug only if the library can't express per-connection
scope cleanly. Either way the tool catalog and scope model below are unchanged —
they are the durable design.

## 3. Tool catalog

Tools are named `<resource>_<verb>` and map onto existing Ash actions / domain
functions (the same ones the REST controllers and `arb` subcommands already
call). Each tool declares a JSON Schema for its inputs; returns are structured
JSON. `R` = readable, `W` = writable.

| Tool | Tier | R/W | Backs onto (Ash action / domain fn) |
|---|---|---|---|
| `task_show` | worker, coordinator | R | `Ash.get(Issue, id)` |
| `task_list` | coordinator | R | `Ash.read(Issue)` + filters |
| `task_ready` | coordinator | R | `Issue.ready/1` |
| `task_update_progress` | worker (own task) | W | `Ash.update(issue, …, action: :update)` — notes / qa_notes / deployment_notes only |
| `task_create` | coordinator | W | `Ash.create(Issue, …)` |
| `task_update` | coordinator | W | `Ash.update(issue, …, action: :update)` (status/priority/…) |
| `task_close` | coordinator | W | `Ash.update(issue, %{reason}, action: :close)` |
| `task_reopen` | coordinator | W | `Ash.update(issue, …, action: :reopen)` |
| `dep_add` / `dep_remove` | coordinator | W | `Ash.create/destroy(Dependency)` |
| `convoy_status` | worker (own), coordinator | R | `Ash.get(Convoy, id)` + calcs |
| `convoy_list` / `convoy_create` / `convoy_add_member` / `convoy_close` | coordinator | R/W | `Convoy` actions / `ConvoyMembership.:add` |
| `inbox_check` | worker (own task), coordinator | R | `Messages.inbox/2` + `mark_read` |
| `notify_list` | worker (own ws), coordinator | R | `Messages.recent_notifications/2` |
| `message_send` | worker, coordinator | W | `Messages.send_mail/1` — coordinator→direction, worker→flag-to-sibling |
| `worker_list` | coordinator | R | `Ash.read(Workers.Run)` / live snapshot |
| `worker_dispatch` | **coordinator only** (`can_dispatch`) | W | `Arbiter.Worker.Dispatch.dispatch/2` |
| `worker_resume` | **coordinator only** (`can_dispatch`) | W | `Arbiter.Worker.Dispatch.resume/2` |
| `worker_review` | **coordinator only** (`can_dispatch`) | W | `Arbiter.Worker.Dispatch.dispatch/2` (`review: true`) |
| `worker_stop` | coordinator | W | `Arbiter.Worker.stop/2` |
| `tracker_claim` | coordinator | W | `Arbiter.Tasks.Claim.claim/3` |
| `tracker_sync` | coordinator | W | `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2` |
| `workspace_show` | worker, coordinator | R | `Ash.get(Workspace, id)` (config/security posture) |
| `workspace_list` | coordinator | R | `Ash.read(Workspace)` — id/name/prefix/tracker only |
| `usage_summarize` | coordinator | R | `Arbiter.Usage.summarize/1` |

Notes:

- **`message_send` is the single message tool, at both tiers.** Earlier drafts
  of this table listed both `message_send` and a coordinator-only
  `worker_message`; the live build shipped only `message_send` available to both
  tiers: a coordinator sends a `:direction` from `"coordinator"`; a worker raises
  a `:flag` from its own bound task to a sibling (the documented "flags to
  siblings" capability). The sender identity is set from the scope, never the
  client, and pinned to the scope's workspace.
- **The worker-dispatch tools (`worker_dispatch` / `worker_resume` /
  `worker_review`) all carry the dispatch-recursion guardrail** (`can_dispatch` +
  `depth`, §4.3) — each spawns a worker. `worker_stop` is teardown only and
  does not require `can_dispatch`.
- **`workspace_list` is the one deliberate cross-workspace read.** Every other
  tool filters to the scope's bound `workspace_id`; `workspace_list` is a
  read-only enumeration of non-sensitive summary fields (id/name/prefix/tracker)
  so a coordinator can discover which workspaces exist. Full config and security
  posture stay behind `workspace_show`, which only ever returns the bound
  workspace.

- **`task_update_progress` is the worker's only write.** It is a narrowed
  alias over `Issue.:update` that accepts *only* `notes`, `qa_notes`,
  `deployment_notes` for the worker's **own** bound task — the structured
  replacement for today's `arb issue update <id> --qa-notes …` step the work
  prompt requires before `arb done`. A worker cannot flip status, reprioritize,
  or touch another task through it.
- **`arb done` stays a stdout sentinel, not a tool.** Completion detection is a
  regex on the agent's stdout (`Worker.ClaudeSession`, `~r/\barb done\b/` against
  assistant text only). It is not an Arbiter API call and does not become an MCP
  tool — the agent still prints the line.

### 3.1 Explicitly out of scope (and why)

The MCP server is the **agent-facing** surface: the structured domain
operations an agent or coordinator legitimately performs from inside its loop.
A large fraction of the `arb` CLI is **not** that — it is the *operator-on-the-
box* surface — and is deliberately **not** exposed as MCP tools. Omitting them
is a design decision, not an oversight:

- **Host / runtime lifecycle — `start`, `restart`, `update` (deploy),
  `install-cli`, `install-service`.** These manage the BEAM and the host the
  server runs *in*. `restart`/`update` are active footguns over MCP: an agent
  restarting the BEAM it is connected to is the `can_sling` recursion problem in
  a worse form — it would tear down the very server (and session) issuing the
  call. These belong to the operator with shell access, not to a tool behind the
  server's own transport.
- **Diagnostics — `doctor` / `server doctor`, `version`, `where`, `init`.**
  Box-introspection and one-time scaffolding. They answer "is this install
  healthy / where does it live / set it up", questions the operator asks from a
  shell, not domain operations an agent performs. No agent workflow needs them,
  and `where`/`version` would leak host layout for no benefit.
- **Auth bootstrap — `mcp token mint` / `mcp token verify`.** A token tool
  cannot live behind the token it issues: minting is the step that *grants* MCP
  access, so it must run from the trusted operator context (the dispatch path mints
  per-spawn; `arb mcp token` mints for operator tooling), never as a call an
  already-connected — and therefore already-scoped — client can make. Exposing
  it would let any coordinator token mint a broader one, collapsing the scope
  model.
- **Config mutation — `config get` / `set` / `unset`.** Blast radius: workspace
  config drives trackers, vernacular, `rig_paths`, security posture. A bad `set`
  clobbers all of it for every future dispatch. This is operator-only. If a
  future autonomous coordinator genuinely needs it, it should be gated behind a
  **new strict `operator` tier** (not `coordinator`), reusing the before/after
  diff that `arb config set` already enforces — not bolted onto the existing
  tiers.
- **Aggregate UX — `prime`.** A convenience command that bundles several reads
  into one human-oriented briefing. Reconstructable from the granular read tools
  (`task_show`, `inbox_check`, `convoy_status`, `notify_list`, …), so it adds a
  second, divergent code path for no new capability. Agents compose the granular
  tools instead.

The throughline: MCP carries **domain** operations, gated by scope. **Host,
lifecycle, auth-bootstrap, and config-mutation** operations are operator
concerns — they either cannot safely live behind the server's own token, or
have a blast radius that does not belong to an agent. They stay on the `arb`
CLI, reached by an operator with shell access to the box.

## 4. Scope tokens, not code paths

Capability is a pure function of the bearer token presented on the MCP
connection. The token is validated and decoded into claims by
`Arbiter.MCP.Scope`, which is the single enforcement point: it holds the
session's bound identity and **rejects out-of-scope calls** rather than trusting
the agent.

### 4.1 Claims

```elixir
%Arbiter.MCP.Scope{
  tier:         :worker | :coordinator,
  workspace_id: "uuid",          # every call is filtered to this workspace
  task_id:      "bd-…" | nil,    # worker tier: the one task it may read/progress
  repo:         "shipyard" | nil,# worker tier: its repo
  can_dispatch: false | true     # coordinator-only; the recursion guardrail
}
```

| Tier | Reads | Writes | Dispatch |
|---|---|---|---|
| `worker` | its own task, its own convoy, its mailbox, its workspace config | progress/qa/deployment notes on **its own task**; flags to siblings | **never** |
| `coordinator` | across the workspace | create/update/close tasks, deps, convoys; dispatch | yes |

The `worker` tier is deliberately narrow — it should not list arbitrary tasks,
dispatch, or touch another convoy's state. The MCP layer enforces this; we do
not rely on prompt discipline. (There is no Ash policy/actor framework in the
domain today — workspace isolation is done by filtering `workspace_id` at query
time — so the scope plug is where capability lives.)

### 4.2 Token shape and validation

A signed, expiring token (recommend `Phoenix.Token` — already available, no new
dep — or a JWT if we later need cross-service verification) carrying the claims
above. It is minted **per spawn** by the dispatch path (see §5) with the
worker's task/repo/workspace baked in, and validated on every MCP request by the
scope plug. Header transport: `Authorization: Bearer <token>` (what Claude Code,
Gemini, and Codex all send for HTTP MCP servers). Reject invalid/expired tokens
with HTTP 401; reject in-scope-but-not-permitted calls with an MCP error
envelope (JSON-RPC error), not a transport error, so the agent gets a usable
"not allowed" rather than a dropped connection.

### 4.3 Recursion / loop guardrail

A `coordinator` that can dispatch *and* is itself an agent could spawn workers
that connect back to the same server. Two guards:

1. **Only `can_dispatch` (coordinator) tokens may call `worker_dispatch`.** A
   worker with an over-broad token still cannot dispatch its own workers —
   `worker` tier never carries `can_dispatch`.
2. **Depth limit.** Mint per-spawn tokens with a `depth` claim; the dispatch tool
   refuses past a configured max. Cheap insurance against a misconfigured
   coordinator fan-out.

## 5. Per-agent config injection (the only agent-specific surface)

The tools are written once; only the spawn-time config file differs. This rides
the **existing** worker-spawn seam — no new spawn path.

A small behaviour `Arbiter.MCP.AgentConfig` with one callback per agent type
emits the right config pointing at the same Arbiter MCP URL with the right scope
token:

```elixir
@callback write_mcp_config(worktree :: Path.t(), opts :: keyword()) :: :ok
# opts carries: mcp_url, scope_token, server_name
```

| Agent | Where it lands | Shape |
|---|---|---|
| **Claude Code** (Phase 1) | `.mcp.json` in the worktree (or `--mcp-config <file>`) | `{"mcpServers":{"arbiter":{"type":"http","url":"…/mcp","headers":{"Authorization":"Bearer <token>"}}}}` |
| **Gemini CLI** (Phase 3) | `.gemini/settings.json` or `gemini mcp add` | bonus: Gemini's `includeTools`/`excludeTools` allowlist (most-restrictive-wins) is a clean secondary per-worker scoping hook |
| **Codex** (Phase 3) | `.codex/config.toml` (`[mcp_servers.arbiter]`) | **caveat:** Codex MCP support is newer and has reports of silent connect failures — verify the session with a `/mcp`-equivalent check rather than trusting the spawn |

### 5.1 Where it cuts in the spawn path

The injection point already exists. For Claude, the seam is one of:

- `Arbiter.Agents.Claude.spawn_env/1`
  (`apps/arbiter/lib/arbiter/agents/claude.ex`) — env injected into the port;
- `Arbiter.Agents.Claude.ConfigDir.ensure/0`
  (`apps/arbiter/lib/arbiter/agents/claude/config_dir.ex`) — already writes the
  isolated `CLAUDE_CONFIG_DIR` `settings.json` + `CLAUDE.md`; add a `.mcp.json`
  here, or pass `--mcp-config` from `default_argv/2`
  (`apps/arbiter/lib/arbiter/agents/claude.ex`, `default_argv/2`);
- the token is minted in `Arbiter.Worker.Dispatch`
  (`apps/arbiter/lib/arbiter/worker/dispatch.ex`, where `build_agent_session_opts/4`
  already assembles per-spawn opts) with the task/repo/workspace claims, and
  threaded to the adapter.

This mirrors how the security policy is already resolved per dispatch and mapped
per adapter (`Arbiter.Agents.SecurityPolicy` →
`Arbiter.Agents.Claude.Security`): MCP access is the same kind of per-spawn
capability grant, resolved centrally and translated per agent. Note one known
cosmetic quirk: Claude Code's `/mcp` dialog shows header-bearer HTTP servers as
"not authenticated" even when the token works — the auth indicator only tracks
OAuth state. The connection and tool calls still authenticate.

## 6. Overlap with the `arb` CLI (the guardrail the issue raises)

If a session can call MCP tools **and** shell out to `arb`, there are two routes
to the same mutation and the model will sometimes pick the worse one. Decision
for the first cut:

- **MCP supplements `arb` for workers; it does not yet replace it.** A worker
  still needs Bash for git, tests, and `arb done` (the stdout sentinel). We add
  MCP tools for the structured ops (`task_show`, `inbox_check`,
  `task_update_progress`, `message_send`) and **steer the generated `CLAUDE.md`
  / work prompt toward the tools** for those ops, while leaving `arb` available.
  We do not exclude Bash (it's load-bearing for the actual work).
- **Re-evaluate replacing `arb` for coordinator-scope clients** once a Mayor
  agent exists — that session mutates state all session long and is the strongest
  case for tools-only. Until then the operator's `arb`/dashboard is the
  coordinator and needs no change.

This keeps Phase 1 additive and reversible: if the tools underperform, the
prompt steering is a one-line revert and `arb` is untouched.

## 7. What this design reuses vs. adds

Reuses, unchanged:

- **Domain layer.** Tool handlers call the same Ash actions the REST controllers
  call. No new domain code, no new source of truth.
- **Spawn path.** Token minted in `Dispatch`; config written at the existing
  `ConfigDir`/argv seam; same per-dispatch resolution shape as security policy.
- **Completion + review protocol.** `arb done` stays a stdout sentinel; review
  gate `VERDICT:` unchanged. MCP is a side channel for structured reads/writes,
  not a replacement for the lifecycle.
- **Usage ledger.** No change; `Arbiter.Usage.Event` already provider-neutral.

Adds:

- `Arbiter.MCP` — transport mount, `Scope` plug, `Tools.*` modules, `AgentConfig`
  behaviour + Claude adapter.
- One MCP dependency (`anubis_mcp`, pending spike sign-off).
- A signed scope-token minting/validation path.

## 8. Phasing

Each phase is independently shippable.

### Phase 1 — read tools, Claude Code, two tiers
- `Arbiter.MCP` mounted on :4848 via Streamable HTTP (`anubis_mcp` or Plug).
- `Arbiter.MCP.Scope` token mint (in `Dispatch`) + validate (plug); two tiers.
- Read tools: `task_show`, `task_ready`, `convoy_status`, `inbox_check`,
  `workspace_show`; plus the one narrowed write `task_update_progress`.
- `Arbiter.MCP.AgentConfig` + Claude `.mcp.json` adapter, wired into the spawn.
- Steer the generated `CLAUDE.md` toward the tools for those ops.
- Exit criteria: a dispatched Claude worker reads its task and writes its
  completion notes via MCP tools; existing suite green; an out-of-scope call
  (e.g. a worker token calling `task_list`) is rejected with a JSON-RPC error.

### Phase 2 — mutating tools behind coordinator scope
- `task_create` / `task_update` / `task_close` / `task_reopen`, `dep_*`,
  `convoy_*`, the `worker_*` lifecycle family (`worker_dispatch` /
  `worker_resume` / `worker_review` / `worker_stop` / `worker_list`),
  `message_send`, `notify_list`, the `tracker_*` bridge (`tracker_claim` /
  `tracker_sync`), `workspace_list`, `usage_summarize`.
- Dispatch-recursion guardrail (`can_dispatch` + depth) on every worker-dispatch
  tool (`worker_dispatch` / `worker_resume` / `worker_review`).
- Wire the operator's coordinator-scope client; evaluate retiring `arb` shell-out
  for it.

### Phase 3 — Gemini + Codex adapters
- `AgentConfig` adapters for `.gemini/settings.json` and `.codex/config.toml`.
- Use Gemini `includeTools`/`excludeTools` as a secondary scope hook.
- Add the Codex post-spawn `/mcp`-equivalent connect check.

## 9. Open questions

1. **Library vs. hand-roll** — settle on `anubis_mcp` after a one-day spike
   against Claude Code's `initialize` handshake and per-connection scope.
2. **Token type** — `Phoenix.Token` (no new dep, single service) vs. JWT (if we
   later verify tokens off-BEAM). Phase 1 leans `Phoenix.Token`.
3. **Mayor** — when an autonomous coordinator agent lands, does it get
   `coordinator` scope wholesale, or a third intermediate tier? Defer until the
   agent exists; the two-tier model is forward-compatible.
4. **Tool-vs-CLI steering strength** — how hard to push the prompt toward MCP
   tools without excluding Bash. Measure tool-call adoption on Phase 1 workers
   before tightening.

## 10. References

- MCP transport (Streamable HTTP supersedes HTTP+SSE):
  <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>
- Elixir MCP SDK (`anubis_mcp`, maintained fork of `hermes_mcp`):
  <https://hexdocs.pm/anubis_mcp/readme.html>
- Claude Code remote MCP config (`.mcp.json`, `type:"http"`, bearer headers):
  <https://code.claude.com/docs/en/mcp>
- In-repo seams: `docs/agent-harness-design.md` (agent adapter),
  `docs/worker-security.md` (per-spawn capability grant).
