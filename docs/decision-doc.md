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

**Updated estimate:** **24-37 days of focused work**, or **5-7 calendar weeks** at the pace described earlier (3-4 hours/day of Ryan direction, 2-3 polecat PRs/day). Closer to the high end if Tier 2 workflows must be feature-complete by cutover.

This is honest. I would rather over-estimate now than discover scope mid-flight.

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
2. **gte-002 Ash Issue resource** — fields, actions (create/read/update/close), `status` FSM (open/in_progress/closed), `priority` (P0-P4), `issue_type` enum, audit via `ash_paper_trail`. Acceptance: unit tests cover create/close/status-transition. [needs: gte-001]
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
16. **gte-016 Workflows.Work module** — implement `mol-polecat-work` semantics as `use Workflow`. [needs: gte-015]
17. **gte-017 sling command** — `bd2 sling <bead> <rig>` → spawn polecat, attach workflow. Acceptance: end-to-end works on a no-op task. [needs: gte-012, gte-016]

**Phase 2 milestone:** use Elixir-side polecats to build Phase 3 + 4. Two-stage dogfooding.

### Phase 3: PR + Jira watchers + peer review (4-6 days)

18. **gte-018 GitHub module** — open PR, get state, list reviews, comment, resolve thread, merge. [needs: gte-001]
19. **gte-019 Jira module** — fetch issue, transition, write custom fields (ADF). [needs: gte-001]
20. **gte-020 PRTemplate module** — read `.github/pull_request_template.md`, fill sections from bead context. [needs: gte-018]
21. **gte-021 Workflows.CodeReview module** — peer-review formula. Output: `reviews/<branch>.md` (local repo) OR GH inline comments (remote). Configurable. [needs: gte-015, gte-018]
22. **gte-022 Workflows.PRPatrol GenServer** — replaces `mol-pr-feedback-patrol`. Subscribes to GH webhooks or polls. Dispatches polecats on actionable PRs. [needs: gte-018, gte-017]
23. **gte-023 Merge queue (Refinery) GenServer** — subscribes to `polecat:done` events, opens PRs, monitors approval+CI, merges. [needs: gte-018, gte-022]

**Phase 3 milestone:** can run the full lifecycle in Elixir without GT. Old GT can be paused.

### Phase 4: LiveView + migration cutover (3-5 days)

24. **gte-024 Dashboard LiveView** — active polecats, recent beads, PRs in flight, escalations. [needs: gte-022, gte-023]
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

## Open questions

1. **Database choice.** Postgres is the obvious pick (Ash works best with it). SQLite is tempting for "local-only" simplicity but loses concurrent-write story. Recommend Postgres. **Action: confirm.**
2. **Where does Claude Code actually run?** Today GT spawns `claude --dangerously-skip-permissions` in a tmux session. We can do the same (Port + tmux), or just Port without tmux (simpler, no attach-from-terminal). **Recommend: Port without tmux.** You attach via `iex --remsh` if needed.
3. **Reviewer polecat output format.** Local repo means no GitHub inline comments by default. Options: (a) `reviews/<branch>.md` written by reviewer polecat, builder reads/responds in markdown; (b) review beads linked to the work bead. **Recommend (a)** for the local-repo flow — simpler, single source of truth in the repo.
4. **Audit-log retention.** Every state transition goes into `audit_events` table. With high polecat throughput this grows. Default 90 days? Configurable? **Recommend: keep forever for now, add cleanup in Phase 5.**
5. **`hq-spq` (refinery PR-shepherd bead I filed earlier today).** `mol-pr-feedback-patrol` already exists. Close `hq-spq` as duplicate, or keep open as "verify it actually runs"? **Recommend: close as duplicate, note the formula exists.**
6. **The full GT formula library — port all 47 or just the ones we use?** Strongly recommend **only the ones we use**. Today's session used `mol-polecat-work`, `mol-refinery-patrol` (indirectly), `mol-pr-feedback-patrol` (we'd benefit from), `mol-polecat-code-review` (for our peer-review process). That's 4. Skip the other 43 unless evidence emerges they're needed.

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
