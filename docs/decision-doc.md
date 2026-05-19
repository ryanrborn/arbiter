# gt-elixir — Phase 0 decision doc

**Status:** draft for review
**Date:** 2026-05-18
**Author:** Mayor (acting under autonomy grant from Ryan)
**Scope:** Define what to port from Gas Town, what to drop, what to defer. Produce a bead graph for Phases 1-4 implementation.

## Revised time estimate (read first)

My original estimate of 15-22 days assumed I understood GT's surface. Phase 0 research revealed substantially more sophistication than I saw in one operational session:

- 47 formulas (workflow templates) including the planning pipeline (`mol-idea-to-plan`), peer review (`mol-polecat-code-review`), PR shepherd (`mol-pr-feedback-patrol`), and TDD/security composition primitives
- Cross-rig infrastructure workers (Dogs), Mountain-Eater epic orchestration, capacity-controlled scheduler, synthesis (cross-leg aggregation), Wasteland federation via DoltHub
- A composition system (extends / expansions / aspects) that's genuinely well-designed

**Updated estimate:** **28-42 days of focused work**, or **6-8 calendar weeks** at the pace described earlier (3-4 hours/day of Ryan direction, 2-3 polecat PRs/day). Includes:
- 2-3 extra formulas in scope (6 total, not 4) per Ryan's direction
- Persona/vernacular configurability system (DB-stored, user-defined)
- External tracker abstraction with pluggable adapters (`Tracker.None` MVP, `Tracker.Jira` MVP, `Tracker.Linear` / `Tracker.GitHub` deferred)
- Postgres + Quantum (switched from SQLite 2026-05-19 — see decision 1)

**Bead count: 33** (gte-001 through gte-028 + gte-P1 through gte-P4 + gte-029).

This is honest. I would rather over-estimate now than discover scope mid-flight.

## Decisions locked (from 2026-05-18 review)

1. **Database:** **Postgres** (via `ash_postgres`). Was SQLite originally; switched 2026-05-19 after verifying `ash_sqlite` is still 0.x (v0.2.17) and explicitly missing Aggregate support — needed for our `Convoy.progress` derived field. `ash_postgres` is at v2.9+ (mature) and is the canonical Ash data layer. Local Postgres is run via `compose.yml` at the repo root (`docker compose up -d`). **Job scheduling:** Quantum + GenServer queues. Skip Oban for now but keep the option open (Oban + Postgres is the gold standard if we need it later — switching is trivial since we're already on Postgres).
2. **Claude session model:** **Port-only** (no tmux). Polecat output streams to LiveView dashboard. Attach via `iex --remsh` if live debugging needed.
3. **Reviewer polecat output:** **Markdown files** at `reviews/<branch>.md` in the local repo. Builder polecat reads, responds in-line, reviewer re-reviews until clean.
4. **Audit retention:** **Forever for now.** Add cleanup tools in Phase 5.
5. **`hq-spq`:** **Close as duplicate** of `mol-pr-feedback-patrol` (which already exists in GT).
6. **Formulas to port (6):** `mol-polecat-work`, `mol-polecat-code-review`, `mol-pr-feedback-patrol`, `mol-refinery-patrol`, `mol-polecat-conflict-resolve`, `shiny`. Add more on evidence.
7. **NEW: Persona / vernacular configurability — DB-stored, user-defined.** User-facing strings (and CLI command aliases) stored as a JSON column on the `Workspace` (or "Fleet") Ash resource. **No code-shipped persona list** — users define their own vocabulary in the DB at setup time. Ryan's example: "Fleet" where each rig is a ship, each ship has a captain, he's the admiral. Internal Elixir names (`Polecat.GenServer`, `Refinery`, etc.) stay stable; the user-facing layer reads from `Workspace.vernacular` at runtime.

   **Schema:**
   ```
   workspaces table:
     id, name, description, vernacular (JSON), created_at, updated_at

   vernacular JSON shape (all keys optional, fall back to "gas-town" defaults):
     {
       "coordinator": "Admiral",      // internal: mayor
       "worker": "Acolyte",           // internal: polecat
       "merge_queue": "Reclamation",  // internal: refinery
       "monitor": "Inquisitor",       // internal: witness
       "watchdog": "Grand Moff",      // internal: deacon
       "issue": "Directive",          // internal: bead
       "batch": "Strike Force",       // internal: convoy
       "rig": "Ship",                 // internal: rig
       "epic": "Campaign",            // internal: mountain
       "aliases": {
         "deploy": "sling",           // CLI: bd2 deploy → sling
         "report": "done",
         "muster": "ready"
       },
       "emoji": {
         "worker": "⚔️",
         "issue": "📜"
       }
     }
   ```

   `Vernacular.label(:worker)` reads current workspace's `vernacular["worker"]`, falls back to "polecat". `Vernacular.alias(:deploy)` returns `:sling`. Everything is data, not code.

8. **NEW (2026-05-19): External tracker abstraction.** gt-elixir must support multiple external trackers (Jira for work, Linear / GitHub Issues / Notion for personal projects, or NO external tracker for local-only). Tracker behaviour with pluggable adapters. Original plan was Jira-centric; this corrects it.

   **Behaviour** (`gt_core/lib/gt_core/trackers/tracker.ex`):
   - `fetch(ref) :: {:ok, map} | {:error, term}`
   - `transition(ref, to) :: :ok | {:error, term}`
   - `update_fields(ref, fields) :: :ok | {:error, term}`
   - `link_for(ref) :: String.t()`
   - `parse_ref(string) :: {:ok, ref} | :error`
   - `list_transitions(ref) :: {:ok, [atom]} | {:error, term}`

   **Adapters:**
   - `Tracker.None` — no external tracker (MVP, Phase 2). Bead system is the only source of truth.
   - `Tracker.Jira` — Atlassian REST + ADF (MVP, Phase 3). Replaces original gte-019 scope.
   - `Tracker.Linear` — Markdown + GraphQL (Phase 5, deferred).
   - `Tracker.GitHub` — Markdown + REST (Phase 5, deferred).

   **Issue resource columns (updated):**
   - `tracker_type :: enum(:none, :jira, :linear, :github)` (default `:none`; inherited from workspace if not set per-bead)
   - `tracker_ref :: String.t() | nil` (the external ID, e.g. `"VR-17585"`)
   - Removed: free-form `external_ref` string.

   **Rich content (qa_notes, deployment_notes, description, acceptance):** stored in bead as **Markdown**. Adapters convert at write time. Jira: Markdown → ADF (helper from 2026-05-18). Linear/GitHub: Markdown is native. None: no-op.

   **Per-workspace tracker config (extends the vernacular JSON):**
   ```json
   {
     "vernacular": { ... },
     "tracker": {
       "type": "jira",
       "config": {
         "host": "leotechnologies.atlassian.net",
         "project_key": "VR",
         "credentials_ref": "env:JIRA_TOKEN"
       }
     }
   }
   ```
   For personal projects: `"tracker": {"type": "none"}` and the bead system stands alone.

   **Per-bead override:** if a workspace has Jira default but you want one bead untracked (e.g., infra work), set `bead.tracker_type = :none`.

## Tier 1 — Definitely port (MVP core)

These are the features Ryan used today and that the system would be useless without:

| GT feature | Elixir target | Notes |
|---|---|---|
| **Bead ledger** | `Beads` context, Ash resource `Issue` with audit + deps + status FSM | Ash gives policies, audit, derived state. Postgres-backed. |
| **CLI shim** | Escript `bd2` that calls Phoenix REST/socket | Replaces bd entirely. Reuse familiar surface (show/create/close/list/update). |
| **Polecat lifecycle** | `Polecat.Supervisor` (DynamicSupervisor), `Polecat.GenServer`, `Worktree` module | Spawn Claude in worktree, monitor, emit events. |
| **Mayor coordinator** | LiveView dashboard | Realtime view of active polecats, beads in flight, PRs. |
| **GitHub PR integration** | `GitHub` module using Req + GH REST/GraphQL | Open PR, poll, merge, comment, resolve threads. |
| **Jira integration** | `Jira` module using Req | Fetch, transition, custom field writes (ADF for QA Testing Notes / Deployment Notes). |
| **Refinery (merge queue)** | `MergeQueue` GenServer per rig | Subscribes to "polecat done" events, opens PRs, monitors, drives merge. |
| **Integration-branch routing** | Config (`config/runtime.exs`) per team | Dolphin → integration/dolphin, etc. Default = development. |
| **Branch naming convention** | `BranchNamer` module driven by bead type + Jira key | feature/VR-#####-slug or bugfix/VR-#####-slug. |
| **PR template population** | `PRTemplate` module reads `.github/pull_request_template.md` | Polecats emit compliant PR bodies automatically. |

## Tier 2 — Port for v1 (important workflows)

These are workflows that exist in GT and that Ryan's flow benefits from:

| GT feature | Elixir target | Notes |
|---|---|---|
| **Workflow engine** | Behaviour `Workflow` + `WorkflowMachine` (GenStateMachine) + macro DSL | Steps with deps, vars, composition. Replaces the TOML formula engine with Elixir-native. |
| **`mol-polecat-work`** | `Workflows.Work` module implementing `Workflow` | Standard 5-step lifecycle: load-context, design, implement, verify, submit. |
| **`mol-polecat-code-review`** | `Workflows.CodeReview` | Peer-review pattern. Output: review beads or `reviews/<branch>.md` (local-only repo flow). |
| **`mol-pr-feedback-patrol`** | `Workflows.PRPatrol` GenServer | Closes `hq-spq` (duplicate; this already exists in GT as a formula). |
| **Convoy concept** | `Convoy` Ash resource + LiveView card | Batch of related beads with synthesis step. |
| **Composition (extends/expansions/aspects)** | Macro `use Workflow, extends: SomeOther, expansions: [...], aspects: [...]` | TDD as expansion, security-audit as aspect. Faithful to GT semantics. |

## Tier 3 — Defer to v2

These are real features but high-cost-low-frequency. Build later if needed:

| GT feature | Why deferred |
|---|---|
| **`mol-idea-to-plan`** (6-polecat PRD review pipeline + plan-align rounds) | Sophisticated and useful but expensive to build. Can use existing GT formula via mol-prd-review until v2. |
| **Mountain-Eater** (epic orchestration with stall detection, skip-after-N-failures) | Useful when running many beads. Build when first big epic warrants it. |
| **Synthesis** (cross-leg aggregation step) | Specific to multi-leg convoys. Build when a convoy needs it. |
| **TDD expansion / security audit aspect as first-class** | Build composition system in Tier 2; these specific compositions can be data, not engine work. |
| **Scheduler with capacity controls** | Needed when running >=5 concurrent polecats. Trivial to add later via Task.Supervisor with max_children. |

## Tier 4 — Drop

These don't justify their cost in the Elixir version:

| GT feature | Drop reason | Replaced by |
|---|---|---|
| **Daemon** | OTP supervision tree IS the daemon | `Application.start/2` + supervisors |
| **Boot (daemon-tick watchdog)** | Same | OTP supervisor restart strategies |
| **Per-rig background witnesses/refineries** | 12 idle Claude sessions burning tokens | On-demand spawn under DynamicSupervisor |
| **Dolt server + bd CLI separation** | The bd-to-Dolt routing layer is the root cause of P0 bug `hq-68h` | Phoenix app + Postgres + Ecto (atomic transactions, no silent writes) |
| **Mail / nudge dual-channel system** | Notification spam, retry loops, echo storms | Phoenix.PubSub topics |
| **Formula TOML format** | DSL is good, format is incidental | Elixir behaviour + macro DSL (same semantics, native syntax) |
| **Wasteland federation** | Multi-Gastown coordination via DoltHub | Out of scope for our team's needs |
| **Most dog formulas** (mol-dog-checkpoint, -compactor, -reaper, -doctor, -stale-db, etc.) | Postgres doesn't need most of this maintenance | Standard Postgres ops + `Quantum` for periodic tasks |
| **Towers of Hanoi formulas** | Test artifacts | Real test suite |
| **Boot's "when to wake" reasoning** | OTP supervision strategies | `:permanent` / `:transient` / `:temporary` |
| **The `.beads/dolt/` local clone pattern** | Source of today's silent write-loss | Single SQL connection to Postgres, autocommit on |
| **`.beads/issues.jsonl` as passive export** | Source of import-on-read fallback bug | Native Postgres backups + audit table |

## Architecture sketch

```
gt-elixir/
├── apps/
│   ├── gt_core/              # Bead ledger, workflow engine, audit
│   │   ├── lib/gt_core/
│   │   │   ├── beads/        # Ash domain: Issue, Convoy, Dependency, AuditEvent
│   │   │   ├── workflows/    # Workflow behaviour + WorkflowMachine
│   │   │   └── application.ex
│   ├── gt_polecat/           # Polecat lifecycle, worktree, Claude session
│   │   ├── lib/gt_polecat/
│   │   │   ├── supervisor.ex
│   │   │   ├── polecat.ex    # GenServer per active polecat
│   │   │   ├── worktree.ex
│   │   │   └── claude_port.ex
│   ├── gt_integrations/      # External APIs
│   │   ├── lib/gt_integrations/
│   │   │   ├── github.ex
│   │   │   └── jira.ex
│   ├── gt_web/               # Phoenix + LiveView dashboard
│   │   └── lib/gt_web/
│   │       ├── live/dashboard_live.ex
│   │       └── controllers/api_controller.ex  # REST for CLI shim
│   └── gt_cli/               # Escript bd2 / gt2
│       └── lib/gt_cli/
├── config/
│   ├── config.exs
│   └── runtime.exs           # Team integration branch mapping
└── docs/
    ├── decision-doc.md       # this file
    └── workflows.md
```

Single umbrella app. Postgres for everything. No Dolt. No daemon. Supervisors all the way down.

## Bead graph (Phase 1 dispatch plan)

I'll file these as `hq-` beads in the existing GT system once you approve this doc. Each is ~2-4hrs scope, peer-reviewed by a second polecat in a markdown review file under `~/dev/gt-elixir/reviews/`, then merged by Mayor.

Format: `[bead-id] [title] [needs: dep1, dep2]`

### Phase 1: bead ledger + CLI shim (4-6 days)

1. **gte-001 Phoenix umbrella scaffold** — create umbrella, add `gt_core` + `gt_web` apps, add Ash + ash_postgres + ash_authentication deps, set up Postgres for dev. Acceptance: `mix test` passes empty suite, `mix phx.server` starts.
2. **gte-002 Ash Issue resource** — fields, actions (create/read/update/close), `status` FSM (open/in_progress/closed), `priority` (P0-P4), `issue_type` enum, audit via `ash_paper_trail`. **External tracker:** `tracker_type` (enum :none/:jira/:linear/:github, default :none) + `tracker_ref` (string nullable). Rich-content fields (description, acceptance, notes, qa_notes, deployment_notes) stored as **Markdown** (adapters convert on write). Acceptance: unit tests cover create/close/status-transition, tracker_type defaults to :none and can be overridden. [needs: gte-001]
3. **gte-003 Ash Dependency resource** — bead-to-bead edges (blocks/depends-on/relates-to). Acceptance: query `Issue.ready/0` returns beads with no open deps. [needs: gte-002]
4. **gte-004 Ash Convoy resource** — batch of beads with status, progress derived from members. Acceptance: convoy closes when all member beads close. [needs: gte-002]
5. **gte-005 REST API for CLI** — `POST /api/issues`, `GET /api/issues/:id`, `PATCH /api/issues/:id/status`, etc. JSON over local socket. Acceptance: curl-able. [needs: gte-002, gte-003, gte-004]
6. **gte-006 CLI escript (bd2)** — `bd2 show/create/close/list/update/deps`. Acceptance: parity with `bd` subcommand surface used in today's session. [needs: gte-005]
7. **gte-007 Dolt-to-Postgres migration script** — import existing hq + server Dolt DBs into the new system. Acceptance: bead count matches, no data loss. [needs: gte-002, gte-003]
8. **gte-008 Phase 1 integration tests** — end-to-end: create bead, add dep, close dep, query ready, close bead. Acceptance: green. [needs: gte-006]

**Phase 1 milestone:** switch from `bd` to `bd2` for the rest of the port. Eat our own dogfood.

### Phase 2: polecat lifecycle (6-9 days)

9. **gte-009 Worktree module** — `Worktree.create/3`, `Worktree.cleanup/1`, `Worktree.branch/2`. Tested against real git. [needs: gte-008]
10. **gte-010 BranchNamer module** — derive branch name from bead (feature/VR-#####-slug). [needs: gte-002]
11. **gte-011 Polecat GenServer** — per-polecat state machine. States: spawning, working, idle, done. Stores worktree path, branch, bead ref. [needs: gte-009, gte-010]
12. **gte-012 Polecat DynamicSupervisor** — spawn/terminate polecats on demand. [needs: gte-011]
13. **gte-013 Claude session Port wrapper** — spawn Claude Code in the worktree, capture stdout, detect completion signal. [needs: gte-011]
14. **gte-014 Workflow behaviour + macro DSL** — `use Workflow, steps: [:load, :design, :implement, :verify, :submit]`, step deps, vars. [needs: gte-001]
15. **gte-015 WorkflowMachine GenStateMachine** — execute a workflow instance. Persist state to bead. [needs: gte-014, gte-002]
16. **gte-016 Workflows.Work module** — implement `mol-polecat-work` semantics as `use Workflow`. **Submit step is tracker-polymorphic:** calls `Tracker.transition(bead, :done)` via the bead's adapter. Works for `:none`-tracked beads (no-op) and Jira-tracked beads (transitions to Code Complete). [needs: gte-015, gte-019]
17. **gte-017 sling command** — `bd2 sling <bead> <rig>` → spawn polecat, attach workflow. Acceptance: end-to-end works on a no-op task. [needs: gte-012, gte-016]

**Phase 2 milestone:** use Elixir-side polecats to build Phase 3 + 4. Two-stage dogfooding.

### Phase 3: PR + Jira watchers + peer review (4-6 days)

18. **gte-018 GitHub module** — open PR, get state, list reviews, comment, resolve thread, merge. [needs: gte-001]
19. **gte-019 Tracker behaviour + Tracker.None adapter + ref types** — define the `Tracker` behaviour and ship the no-op `Tracker.None` adapter. Define the `tracker_type` enum + `tracker_ref` types. Helper functions: `Tracker.for_bead/1` (resolve adapter from bead's `tracker_type`), `Tracker.parse_ref/2` (delegate to adapter). Acceptance: behaviour defined with @callback specs, None adapter passes all callbacks as no-ops, ref parsing round-trips. [needs: gte-001, gte-002]

  *(Note: original gte-019 was Jira-specific; that scope moved to gte-029 after the 2026-05-19 tracker abstraction decision.)*
20. **gte-020 PRTemplate module** — read `.github/pull_request_template.md`, fill sections from bead context. **Tracker-agnostic:** the section-fill logic doesn't assume Jira; pulls the Jira link from `Tracker.link_for(bead)` (returns empty string for `:none`-tracked beads). [needs: gte-018, gte-019]
21. **gte-021 Workflows.CodeReview module** — peer-review formula. Output: `reviews/<branch>.md` (local repo) OR GH inline comments (remote). Configurable. [needs: gte-015, gte-018]
22. **gte-022 Workflows.PRPatrol GenServer** — replaces `mol-pr-feedback-patrol`. Subscribes to GH webhooks or polls. Dispatches polecats on actionable PRs. [needs: gte-018, gte-017]
23. **gte-023 Merge queue (Refinery) GenServer** — subscribes to `polecat:done` events, opens PRs, monitors approval+CI, merges. [needs: gte-018, gte-022]

29. **gte-029 Tracker.Jira adapter implementing Tracker behaviour** — full Jira adapter: fetch issue, transition, write custom fields (ADF), list transitions, parse `"jira:VR-####"` refs, build links. Markdown → ADF conversion for rich-content writes. Uses Req. **Replaces the original gte-019 Jira-specific scope.** [needs: gte-019, gte-001]

**Phase 3 milestone:** can run the full lifecycle in Elixir without GT. Old GT can be paused.

### Phase 3.5: Vernacular system (1-2 days)

P-1. **gte-P1 Ash `Workspace` resource with JSON config (vernacular + tracker)** — user creates a workspace, optionally sets vernacular and tracker config at creation. Default = `gas-town` vernacular + `:none` tracker (baked-in fallbacks). Single JSON `config` column holds both vernacular and tracker sub-objects. [needs: gte-001, gte-002]
P-2. **gte-P2 `Vernacular` module** — `Vernacular.label(:worker)` reads current workspace's JSON, falls back to defaults. Process-dictionary cache per request/CLI invocation. [needs: gte-P1]
P-3. **gte-P3 CLI alias resolution** — `bd2 deploy` looks up "deploy" in workspace.vernacular.aliases, resolves to `sling`, dispatches. Unknown aliases error with helpful "did you mean" output. [needs: gte-006, gte-P2]
P-4. **gte-P4 LiveView vernacular integration + setup wizard** — dashboard reads `Vernacular.label/1` for all strings. Settings page exposes JSON editor for vernacular (with live preview). [needs: gte-024, gte-P2]

### Phase 4: LiveView + migration cutover (3-5 days)

24. **gte-024 Dashboard LiveView** — active polecats, recent beads, PRs in flight, escalations. Uses Vernacular module. [needs: gte-022, gte-023, gte-P1]
25. **gte-025 Audit log LiveView** — searchable history of every action. [needs: gte-002]
26. **gte-026 Final data migration** — re-run gte-007 against latest GT state. Cutover plan. [needs: all above]
27. **gte-027 Run both systems in parallel for 3-5 days** — verify Elixir handles real work. [needs: gte-026]
28. **gte-028 Decommission GT** — stop daemon, archive Dolt data, document the switch. [needs: gte-027]

**Phase 4 milestone:** cutover complete.

### Phase 5 (Tier 2 polish, post-MVP): 5-8 days

- Composition system: `use Workflow, extends: ..., aspects: [...]`
- `Workflows.PlanReview` — port `mol-plan-review` convoy
- `Workflows.PRDReview` — port `mol-prd-review` convoy
- Mountain-Eater equivalent (`Convoy.Mountain` flag + stall detection)
- Capacity-controlled scheduler (max concurrent polecats)
- **`Tracker.Linear` adapter** — Markdown + GraphQL
- **`Tracker.GitHub` adapter** — Markdown + REST

## Open questions

All resolved 2026-05-18. See "Decisions locked" section above.

## Risks (honest)

| Risk | Mitigation |
|---|---|
| Underestimated scope discovery (more in GT I haven't seen yet) | 5-day buffer baked into estimate; flag immediately if new big-rocks emerge |
| Ash learning curve if I don't already have it deep in muscle memory | Lean on ash-framework-expert agent for resource design questions |
| Port + tmux + Claude Code interaction may have surprises | Spike in Phase 2 (gte-013) before committing to full implementation |
| GT bugs block its own replacement | Per the operating model: fall back to direct Claude session if GT loses >2h |
| Migration cutover data loss | Dual-run for 3-5 days before decommissioning |
| LiveView dashboard scope creep | MVP is non-negotiable: active polecats + recent beads + PRs. Nothing else. |

## What this doc is asking for

Sign-off on:
1. The tier-1 / tier-2 / drop classification
2. The 5-phase bead graph (28 beads)
3. The 24-37 day / 5-7 calendar week timeline
4. The 6 open questions (recommend defaults are flagged)

Once approved, I file the beads in GT (with `gte-` prefix or as `hq-` if creating a new prefix isn't worth it), set up the peer-review markdown convention, and dispatch gte-001.
