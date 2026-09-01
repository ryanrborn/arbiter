defmodule Arbiter.MCP.Catalog do
  @moduledoc """
  The `Arbiter.MCP` tool catalog: the declarative list of Phase 1 tools (name,
  the tiers that may call each, a one-line description, and a JSON Schema for the
  inputs) plus the dispatch path that the transport (`ArbiterWeb.MCP.Plug`) drives
  for `tools/list` and `tools/call`.

  Tier-level visibility is the **only** capability decision made here: a tool is
  visible to — and callable by — a scope iff the scope's tier is in the tool's
  `:tiers`. Data-level rules (own-task, workspace isolation) live in the handlers
  (`Arbiter.MCP.Tools`) via `Arbiter.MCP.Scope`.

  ## Phase 1 catalog

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `task_show` | worker, coordinator | `Ash.get(Issue, id)` + child-progress calcs |
  | `task_ready` | coordinator | `Issue.ready/1` |
  | `inbox_check` | worker, coordinator | `Messages.inbox/2` + `mark_read` |
  | `coordinator_inbox` | coordinator | `Messages.inbox/2` + `mark_read` (coordinator mailbox) |
  | `workspace_show` | worker, coordinator | `Ash.get(Workspace, id)` |
  | `task_update_progress` | worker, coordinator | `Ash.update(issue, …, action: :update)` |

  ## Phase 2 catalog (coordinator tools + the both-tier `message_send`)

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `task_create` | coordinator | `Ash.create(Issue, …)` |
  | `task_update` | coordinator | `Ash.update(issue, …, action: :update)` |
  | `task_close` | coordinator | `Ash.update(issue, …, action: :close)` |
  | `task_reopen` | coordinator | `Ash.update(issue, …, action: :reopen)` |
  | `task_promote` | coordinator | `Ash.update(issue, …, action: :promote_to_ready)` |
  | `task_sync_upstream_close` | coordinator | `Ash.update(issue, …, action: :sync_upstream_close)` |
  | `dep_add` | coordinator | `Ash.create(Dependency, …)` (use `parent_of` to attach a child) |
  | `dep_remove` | coordinator | `Ash.destroy(Dependency)` |
  | `worker_dispatch` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` |
  | `worker_resume` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.resume/2` |
  | `worker_review` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` (`review: true`) / `Arbiter.Reviews.ExternalReview.dispatch/1` (`pr`) |
  | `worker_stop` | coordinator | `Arbiter.Worker.stop/2` |
  | `worker_list` | coordinator | `Arbiter.Worker.list_children/0` |
  | `worker_show` | coordinator | `Arbiter.Worker.whereis/1` + `Worker.state/1`, falls back to `Arbiter.Workers.Run` |
  | `worker_runs` | coordinator | `Ash.read(Arbiter.Workers.Run, task_id: …)`, newest first (accepts synthetic ids) |
  | `worker_log` | coordinator | `Arbiter.Worker.OutputLog.read_lines/1` for one run (by `run_id` or the task's most recent) |
  | `worker_prompt` | coordinator | `Arbiter.Worker.PromptLog.read/1` for one run (by `run_id` or the task's most recent) |
  | `run_log_list` | coordinator | `Ash.read(Arbiter.Workers.Run, task_id: … or …#…)`, task + synthetic children |
  | `external_review_transcript` | coordinator | `Arbiter.Reviews.Transcript.read_lines/1` + `tool_uses/1` for one non-task-linked review (by review record id) |
  | `transcript_capture_stats` | coordinator | `Ash.read(Arbiter.Workers.Run, workspace_id: …)` since the corpus start date, capture rate over Claude-driven runs |
  | `message_send` | worker, coordinator | `Messages.send_mail/1` (flag / direction) |
  | `notify_list` | worker, coordinator | `Messages.recent_notifications/2` |
  | `task_list` | coordinator | `Ash.read(Issue, …)` with filters |
  | `tracker_claim` | coordinator | `Arbiter.Tasks.Claim.claim/3` |
  | `tracker_sync` | coordinator | `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2` |
  | `workspace_list` | coordinator | `Ash.read(Workspace)` (summary fields) |
  | `workspace_config_get` | worker, coordinator | `Ash.get(Workspace, id)` → read `config` / dotted key |
  | `workspace_config_overview` | worker, coordinator | `Ash.get(Workspace, id)` → grouped config summary |
  | `workspace_config_set` | coordinator | `Ash.update(ws, …, action: :patch_config)` deep-merge |
  | `workspace_config_unset` | coordinator | `Ash.update(ws, …, action: :patch_config)` unset |
  | `installation_config_get` | worker, coordinator | `Arbiter.Settings` getters (conductor + credential watchdog) |
  | `installation_config_set` | coordinator | `Arbiter.Settings` setters (conductor + credential watchdog) |
  | `skill_create` | coordinator | `Arbiter.Skills.create_skill/1` |
  | `skill_update` | coordinator | `Arbiter.Skills.update_skill/2` |
  | `skill_delete` | coordinator | `Arbiter.Skills.delete_skill/1` |
  | `skill_list` | worker, coordinator | `Arbiter.Skills.list_skills/0` |
  | `skill_get` | worker, coordinator | `Arbiter.Skills.get_skill/1` |
  | `loop_pending_list` | coordinator | `Arbiter.Loop.list_pending/1` + `evidence_bar/1` |
  | `loop_pending_diff` | coordinator | `Arbiter.Loop.get_pending/1` (full row incl. unified diff) |
  | `loop_pending_apply` | coordinator | `Arbiter.Loop.apply_pending/2` (dispatches to the existing domain API) |
  | `loop_pending_reject` | coordinator | `Arbiter.Loop.reject_pending/2` (soft — the row persists as `rejected`) |
  | `usage_summarize` | coordinator | `Arbiter.Usage.summarize/1` |
  | `queue_resume` | coordinator | `Arbiter.Workflows.Conductor.resume_task/1` (C5 of #482) |
  | `queue_retry_auto_resolve` | coordinator | `Arbiter.Worker.Watchdog.retry_auto_resolve/1` (bd-bspakl) |
  | `queue_restart_watchdog` | coordinator | `Arbiter.Worker.Watchdog.restart/1` (bd-8jixav) |
  | `scheduler_pause` | coordinator | `Arbiter.Board.Autopilot.pause/1` |
  | `scheduler_resume` | coordinator | `Arbiter.Board.Autopilot.resume/1` |
  | `scheduler_status` | coordinator | `Arbiter.Board.Autopilot.paused?/1` |
  | `repo_list` | coordinator | `Arbiter.Tasks.RepoConfig.list_repos()` (mirrors `arb repo list`) |
  | `repo_show` | coordinator | single repo from `list_repos()` |
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  # JSON-RPC / MCP error codes. -32003 is an implementation-defined server error
  # in the reserved -32000..-32099 range; -32602 is "invalid params".
  @code_not_permitted -32_003
  @code_invalid_params -32_602

  @type tool :: %{
          name: String.t(),
          tiers: [Scope.tier()],
          description: String.t(),
          input_schema: map(),
          handler: (Scope.t(), map() -> {:ok, map()} | {:error, {atom(), String.t()}})
        }

  @type call_result ::
          {:ok, map()}
          | {:rpc_error, integer(), String.t()}
          | {:tool_error, String.t()}

  @both [:worker, :coordinator]
  @coordinator [:coordinator]

  # Enum values for the loop-proposal queue tools. Kept as strings here because
  # they go straight into a JSON Schema; `Arbiter.Loop.PendingWrite` holds the
  # authoritative atom constraints.
  @loop_states ~w(proposed hypothesis applied rejected superseded)
  @loop_kinds ~w(skill_patch skill_create difficulty_override config_set repo_doc_patch)

  # The optional `workspace` field every workspace-resolving tool advertises.
  # Coordinator tokens are workspace-agnostic (one token, any workspace); naming
  # a workspace here targets it explicitly. Omitting it resolves the workspace
  # from the referenced entity (e.g. a task's own workspace) or the installation
  # default. A workspace-bound scope (a worker) may only ever name its own.
  @workspace_field %{
    "type" => "string",
    "description" =>
      "Workspace name or id to operate in (optional). Coordinator tokens are " <>
        "workspace-agnostic; omit to resolve from the referenced task or the " <>
        "installation default. A worker may only ever name its own workspace."
  }

  # Tools that call resolve_workspace_id and thus support the optional `workspace` arg.
  # All other tools do not accept a workspace override.
  @workspace_tools ~w(task_ready coordinator_inbox workspace_show quota_get task_create worker_list task_list usage_summarize notify_list tracker_claim tracker_sync graph_create workspace_config_get workspace_config_overview workspace_config_set workspace_config_unset external_review_list)

  @raw_tools [
    %{
      name: "task_show",
      tiers: @both,
      description:
        "Read one task (id, title, status, description, acceptance, and child-progress " <>
          "`child_closed`/`child_total` over its `parent_of` children). A worker reads its " <>
          "own task (the `id` argument may be omitted); a coordinator must pass the `id`. " <>
          "Pass `full: true` to include review fields (notes, qa_notes, deployment_notes, " <>
          "pr_body, pr_ref, tracker_ref, target_branch, repo, assignee, auto_close, timestamps).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Task id (e.g. \"bd-dem49g\"). Optional for a worker (defaults to its own task)."
          },
          "full" => %{
            "type" => "boolean",
            "description" =>
              "When true, return the complete record including notes, qa_notes, " <>
                "deployment_notes, pr_body, pr_ref, tracker_ref, target_branch, repo, assignee, " <>
                "auto_close, and timestamps. Defaults to false (slim payload for workers)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_show/2
    },
    %{
      name: "task_ready",
      tiers: [:coordinator],
      description: "List ready (open, unblocked) tasks in the workspace.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.task_ready/2
    },
    %{
      name: "inbox_check",
      tiers: @both,
      description:
        "Read the mailbox for a task — the structured replacement for `arb inbox`. " <>
          "A worker checks its own task; a coordinator passes `task_id`. " <>
          "Two states: `state: \"unread\"` (default) lists unread messages and marks them read; " <>
          "`state: \"outstanding\"` lists read-but-uncleared messages as a pure read — no mutations.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Recipient task id. Optional for a worker (defaults to its own task)."
          },
          "state" => %{
            "type" => "string",
            "enum" => ["unread", "outstanding"],
            "description" =>
              "Mailbox state to return. \"unread\" (default): unread messages, marked read on return. " <>
                "\"outstanding\": read-but-uncleared messages, no mutations."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.inbox_check/2
    },
    %{
      name: "coordinator_inbox",
      tiers: @coordinator,
      description:
        "Read the coordinator escalation mailbox for the workspace — the structured " <>
          "replacement for `arb message inbox` / `arb inbox`. Lists messages where " <>
          "`to_ref == \"coordinator\"`. Two states: `state: \"unread\"` (default) lists unread " <>
          "messages and marks them read on return; optionally `clear: true` also soft-clears the " <>
          "outstanding tail (mirrors `arb inbox clear`). `state: \"outstanding\"` lists read-but-uncleared " <>
          "messages (the triage queue) as a pure read — no mutations. `state: \"outstanding\"` and " <>
          "`clear: true` are mutually exclusive. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "type" => "string",
            "enum" => ["unread", "outstanding"],
            "description" =>
              "Mailbox state to return. \"unread\" (default): unread messages, marked read on return. " <>
                "\"outstanding\": read-but-uncleared messages, no mutations."
          },
          "clear" => %{
            "type" => "boolean",
            "description" =>
              "Also soft-clear the outstanding tail after listing (mirrors `arb inbox clear`). " <>
                "Only valid with state: \"unread\". Default false."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.coordinator_inbox/2
    },
    %{
      name: "workspace_show",
      tiers: @both,
      description:
        "Show the scope's own workspace: config and the resolved worker security posture.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_show/2
    },
    %{
      name: "quota_get",
      tiers: @both,
      description:
        "Current rate-limit / quota state for the scope's workspace. `claude`: Anthropic's 5h + " <>
          "7d utilization, reset times, status, and which window binds (captured by the local " <>
          "proxy; `null` until the first proxied request), plus an on-demand per-model weekly " <>
          "utilization + extra_usage overage refresh. `codex`: OpenAI session + weekly " <>
          "windows fetched live from the rate-limit endpoint (`null` with a `codex_message` when " <>
          "Codex isn't authenticated or the usage API is unavailable). `gemini` / `antigravity`: " <>
          "live per-model Cloud Code Assist quota (`null` when that CLI isn't authenticated on " <>
          "this host).",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.quota_get/2
    },
    %{
      name: "task_update_progress",
      tiers: @both,
      description:
        "Record progress / completion notes on a task — `notes`, `qa_notes`, `deployment_notes`, " <>
          "`pr_body` only (the structured replacement for `arb issue update --qa-notes …`). A " <>
          "worker may only update its own task and cannot change status or priority.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Task id. Optional for a worker (defaults to its own task)."
          },
          "notes" => %{"type" => "string", "description" => "Free-form progress / working notes."},
          "qa_notes" => %{"type" => "string", "description" => "What QA should verify."},
          "deployment_notes" => %{
            "type" => "string",
            "description" => "Rollout / backout considerations."
          },
          "pr_body" => %{
            "type" => "string",
            "description" =>
              "The worker-authored PR/MR description (Summary / Test plan / References) the " <>
                "MergeQueue opens the task's single canonical PR with."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_update_progress/2
    },

    # ---- Phase 2: coordinator-only mutating tools ----
    %{
      name: "task_create",
      tiers: @coordinator,
      description:
        "Create a task in the workspace. `title` is required; optional `description`, " <>
          "`acceptance`, `priority`, `difficulty`, `issue_type`, `auto_close`, `assignee`, " <>
          "`tracker_type`, …. The task is always created in the coordinator's own workspace. " <>
          "Created tasks land in the board's Backlog (`refined: false`), not its Ready queue, " <>
          "and stay there until a human promotes them from the task detail page. " <>
          "Graph-driven dispatch (`task_ready`, workflow admission) ignores `refined`, so a " <>
          "task that is part of a workflow graph still runs; a standalone task filed here " <>
          "waits for that promotion.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Task title (required)."},
          "description" => %{"type" => "string", "description" => "Markdown body."},
          "acceptance" => %{"type" => "string", "description" => "Markdown acceptance criteria."},
          "notes" => %{"type" => "string"},
          "qa_notes" => %{"type" => "string"},
          "deployment_notes" => %{"type" => "string"},
          "priority" => %{
            "type" => "integer",
            "description" => "0 (P0, highest) .. 4 (P4, lowest). Default 2."
          },
          "difficulty" => %{"type" => "integer", "description" => "0 (D0) .. 4 (D4)."},
          "issue_type" => %{
            "type" => "string",
            "description" => "task | bug | feature | epic | chore | decision."
          },
          "auto_close" => %{
            "type" => "boolean",
            "description" =>
              "When true, this task auto-closes once all its `parent_of` children are closed " <>
                "(≥1 child). Default false."
          },
          "assignee" => %{"type" => "string"},
          "tracker_type" => %{
            "type" => "string",
            "description" => "none | jira | shortcut | linear | github | gitlab."
          },
          "tracker_ref" => %{"type" => "string"},
          "tracker_context_type" => %{
            "type" => "string",
            "description" =>
              "Tracker type for a context-only reference (e.g. \"jira\"). Paired with " <>
                "`tracker_context_ref`. No claim semantics; the referenced ticket is fetched " <>
                "read-only at review dispatch to supply the reviewer with acceptance criteria. " <>
                "Safe to use on coworker-owned tickets."
          },
          "tracker_context_ref" => %{
            "type" => "string",
            "description" =>
              "Tracker issue ref for read-only context (e.g. \"VR-18004\"). The ticket's " <>
                "description is fetched at review dispatch and injected into the reviewer's " <>
                "prompt. No assignment check, no write-back."
          },
          "target_branch" => %{"type" => "string"},
          "repo" => %{
            "type" => "string",
            "description" =>
              "The repo this task belongs to, as a configured `repo_paths` key " <>
                "(e.g. \"emricare/tonic\"). Optional — only needed in a multi-repo " <>
                "workspace, where dispatch otherwise can't tell which checkout the work " <>
                "is for. Every dispatch of the task uses it unless one names another repo."
          }
        },
        "required" => ["title"],
        "additionalProperties" => false
      },
      handler: &Tools.task_create/2
    },
    %{
      name: "task_update",
      tiers: @coordinator,
      description:
        "Update a task in the workspace (status / priority / title / …). To close a task use " <>
          "`task_close`; the `closed` status is rejected here.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."},
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "acceptance" => %{"type" => "string"},
          "notes" => %{"type" => "string"},
          "qa_notes" => %{"type" => "string"},
          "deployment_notes" => %{"type" => "string"},
          "status" => %{"type" => "string", "description" => "open | in_progress."},
          "priority" => %{"type" => "integer"},
          "difficulty" => %{"type" => "integer"},
          "issue_type" => %{"type" => "string"},
          "auto_close" => %{
            "type" => "boolean",
            "description" => "Auto-close this task when all its `parent_of` children are closed."
          },
          "assignee" => %{"type" => "string"},
          "tracker_type" => %{"type" => "string"},
          "tracker_ref" => %{"type" => "string"},
          "tracker_context_type" => %{"type" => "string"},
          "tracker_context_ref" => %{"type" => "string"},
          "pr_ref" => %{"type" => "string"},
          "target_branch" => %{"type" => "string"},
          "repo" => %{
            "type" => "string",
            "description" =>
              "The repo this task belongs to, as a configured `repo_paths` key " <>
                "(e.g. \"emricare/tonic\")."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_update/2
    },
    %{
      name: "task_close",
      tiers: @coordinator,
      description:
        "Close a task in the workspace. Optional `reason`. Also closes the linked external " <>
          "tracker issue by default when the task has a `tracker_ref`; pass " <>
          "`close_upstream: false` to leave it open.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."},
          "reason" => %{"type" => "string"},
          "close_upstream" => %{
            "type" => "boolean",
            "description" =>
              "Also close the linked tracker issue (default true; pass false to opt out)."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_close/2
    },
    %{
      name: "task_reopen",
      tiers: @coordinator,
      description:
        "Reopen a closed task (clears closed_at, returns it to the ready queue, and best-effort " <>
          "reopens the linked tracker issue). The only supported path out of `closed` — `task_update` " <>
          "rejects that transition.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_reopen/2
    },
    %{
      name: "task_promote",
      tiers: @coordinator,
      description:
        "Promote a task from Backlog to Ready (set `refined: true`) via the `:promote_to_ready` action. " <>
          "Coordinator only. Idempotent by design — promoting an already-refined task is a no-op success, " <>
          "not an error.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_promote/2
    },
    %{
      name: "task_sync_upstream_close",
      tiers: @coordinator,
      description:
        "Push a close to the linked tracker issue for a task that's already `:closed` locally " <>
          "but was never synced upstream (e.g. it closed via auto-close rollup or a caller that " <>
          "forgot `close_upstream: true`). Makes no local status change — the task must already " <>
          "be `:closed` and carry a `tracker_ref`. Does not reopen, re-run StopWorker/" <>
          "CleanupWorktree, or re-trigger the parent auto-close rollup.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_sync_upstream_close/2
    },
    %{
      name: "dep_add",
      tiers: @coordinator,
      description:
        "Add a dependency edge between two tasks in the workspace. `type` is one of blocks, " <>
          "depends_on, relates_to, discovered_from, parent_of. Use `parent_of` (from = parent, " <>
          "to = child) to attach a child to a parent task — that is how grouping/epics work; the " <>
          "parent then rolls up child progress and can auto-close.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from_issue_id" => %{"type" => "string", "description" => "The dependent task."},
          "to_issue_id" => %{"type" => "string", "description" => "The dependency target."},
          "type" => %{"type" => "string", "description" => "Edge type (required)."},
          "notes" => %{"type" => "string"},
          "created_by" => %{"type" => "string"}
        },
        "required" => ["from_issue_id", "to_issue_id", "type"],
        "additionalProperties" => false
      },
      handler: &Tools.dep_add/2
    },
    %{
      name: "dep_remove",
      tiers: @coordinator,
      description:
        "Remove dependency edges between two tasks in the workspace. Omit `type` to remove every " <>
          "edge between the pair. Idempotent.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from_issue_id" => %{"type" => "string"},
          "to_issue_id" => %{"type" => "string"},
          "type" => %{
            "type" => "string",
            "description" => "Optional edge type to narrow removal."
          }
        },
        "required" => ["from_issue_id", "to_issue_id"],
        "additionalProperties" => false
      },
      handler: &Tools.dep_remove/2
    },
    %{
      name: "worker_dispatch",
      tiers: @coordinator,
      description:
        "Dispatch a worker to work a task in the workspace. Requires a `can_dispatch` coordinator " <>
          "token and is depth-limited (the dispatch-recursion guardrail). Omitting `provider` " <>
          "resolves the worker from the workspace's `agent.type` config (first healthy provider via " <>
          "ProviderPool). Pass `provider` to override; set `no_agent: true` to park the task " <>
          "in_progress without spawning a worker (hand-off / manual-attach workflows).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task to dispatch (required)."},
          "repo" => %{
            "type" => "string",
            "description" =>
              "Repo to run in. Optional, and a one-shot override: it beats the task's own " <>
                "`repo` assignment, which in turn beats auto-selecting the workspace's sole " <>
                "configured repo."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "provider" => %{
            "type" => "string",
            "enum" => ["claude", "gemini", "codex"],
            "description" =>
              "Override the workspace's default provider. Omit to use the workspace `agent.type` config."
          },
          "no_agent" => %{
            "type" => "boolean",
            "description" =>
              "Dry dispatch — park the task in_progress without spawning a worker. Use for hand-off / manual-attach workflows."
          },
          "with_claude" => %{
            "type" => "boolean",
            "description" =>
              "DEPRECATED alias for `provider: \"claude\"`. `true` → start a Claude worker."
          },
          "force_quota" => %{
            "type" => "boolean",
            "description" =>
              "ADVANCED: bypass the quota gate for this dispatch. Use only for judged-important work when the gate holds despite headroom. Defaults to false (quota-gated)."
          },
          "force_quota_reason" => %{
            "type" => "string",
            "description" =>
              "ADVANCED: optional rationale for bypassing the quota gate. Only used when `force_quota: true`."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_dispatch/2
    },
    %{
      name: "worker_resume",
      tiers: @coordinator,
      description:
        "Re-attach a fresh worker to a task's preserved worktree (`arb resume`), continuing " <>
          "the stopped run rather than restarting. Requires a `can_dispatch` coordinator token and is " <>
          "depth-limited (the dispatch-recursion guardrail).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task to resume (required)."},
          "repo" => %{
            "type" => "string",
            "description" => "Repo to run in (optional; inherited from the task's last run)."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "force_quota" => %{
            "type" => "boolean",
            "description" =>
              "ADVANCED: bypass the quota gate for this resume. Use only for judged-important work when the gate holds despite headroom. Defaults to false (quota-gated)."
          },
          "force_quota_reason" => %{
            "type" => "string",
            "description" =>
              "ADVANCED: optional rationale for bypassing the quota gate. Only used when `force_quota: true`."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_resume/2
    },
    %{
      name: "worker_review",
      tiers: @coordinator,
      description:
        "Dispatch a review-only worker (`arb review`): no worktree, no branch, no merge. Requires a " <>
          "`can_dispatch` coordinator token and is depth-limited. Pass `task_id` to review the PR/MR " <>
          "linked to a task (claude-driven; `with_claude: false` skips the agent), or `pr` (URL or " <>
          "number, + optional `repo`/`workspace`) to review an external / non-arbiter PR through the " <>
          "MR adapter — findings + a verdict are posted to the PR, no task or branch required. For a " <>
          "`pr` review, `follow_up` opens a review_only ReviewPatrol engagement after the verdict so " <>
          "the PR is re-reviewed on new commits and its replies handled (defaults on when the " <>
          "workspace has ReviewPatrol running). A `pr` review is refused when this identity has " <>
          "already left a current approving review on the PR (avoids double-posting an approval), " <>
          "or when the resolved review_automation mode is \"off\" (a hard opt-out repo/workspace " <>
          "policy) — pass `force: true` to override either refusal.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task to review (one of `task_id` or `pr` is required)."
          },
          "pr" => %{
            "type" => "string",
            "description" =>
              "External PR/MR to review: a forge URL, an `owner/repo#N` slug, or a number " <>
                "(pass `repo` so a bare number resolves to owner/repo)."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "Local checkout. Task review: the reviewer's cwd (needs `gh`/`git`). " <>
                "`pr`: resolves owner/repo for a bare PR number."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "(`pr` only) Workspace name/id whose MR provider to target."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "with_claude" => %{
            "type" => "boolean",
            "description" => "(task review) Spawn the reviewer agent (default true)."
          },
          "tracker_context_ref" => %{
            "type" => "string",
            "description" =>
              "Tracker issue ref to fetch acceptance criteria from — read-only " <>
                "context for the reviewer. No claim, no assignment check, no write-back. Safe " <>
                "for coworker-owned tickets (e.g. \"VR-18004\"). On a `pr` review with `follow_up`, " <>
                "it is also carried onto the engagement for re-review intent."
          },
          "tracker_context_type" => %{
            "type" => "string",
            "description" =>
              "Tracker type for `tracker_context_ref` (e.g. \"jira\"). " <>
                "Defaults to the workspace's tracker when omitted."
          },
          "follow_up" => %{
            "type" => "boolean",
            "description" =>
              "(`pr` only) Open a review_only ReviewPatrol engagement after the verdict posts so " <>
                "the PR is re-reviewed on new commits, its author replies are handled, and it is " <>
                "tracked to merge. Dedups on an already-open engagement for the same PR. When " <>
                "omitted, defaults to on iff the workspace has a ReviewPatrol running."
          },
          "automation" => %{
            "type" => "string",
            "enum" => [
              "auto",
              "report_only",
              "propose",
              "flag",
              "notify",
              "off",
              "never",
              "disabled"
            ],
            "description" =>
              "Override the workspace review_automation policy: \"auto\" = review AND post to the " <>
                "PR; \"report_only\" (alias \"propose\") = review fully but post NOTHING — surface " <>
                "findings + proposed comments to the coordinator to greenlight (infra default, " <>
                "human-in-the-loop); \"flag\" (alias \"notify\") = do not review, just flag new " <>
                "commits/replies; \"off\" (aliases \"never\"/\"disabled\") = hard opt-out — refuse " <>
                "to dispatch a reviewer at all, no agent spawned, nothing posted (pass `force: true` " <>
                "to override a single dispatch). When omitted, the mode is resolved from the " <>
                "workspace policy using the PR author (the actual author for a `pr` review; " <>
                "`pr_author` for a task review) or the workspace's `review_automation.repo_overrides` " <>
                "for `repo`."
          },
          "pr_author" => %{
            "type" => "string",
            "description" =>
              "(task review) Login of the PR author, used to resolve the workspace " <>
                "review_automation policy (auto_authors list). Ignored when `automation` is set."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["diff", "repo"],
            "description" =>
              "(`pr` only) Review depth: \"diff\" (default) — the reviewer only sees the unified " <>
                "diff. \"repo\" — additionally traces cross-file consumers of anything the diff " <>
                "changes against a read-only checkout of `repo` (no branch switch, no commit), " <>
                "surfacing downstream call sites a diff-only review would miss. When omitted, " <>
                "resolved from the workspace `review_scope` policy: a configured default, or " <>
                "auto-escalated to \"repo\" when the diff touches a `sensitive_globs` path " <>
                "(e.g. auth/signing code) — cross-cutting or security PRs get the deeper pass " <>
                "without per-dispatch opt-in."
          },
          "force" => %{
            "type" => "boolean",
            "description" =>
              "Skip the self-approve guard (`pr` only: dispatch even when this identity has " <>
                "already left a current approving review on the PR) AND/OR the review_automation " <>
                "\"off\" guard (`pr` and `task_id`: dispatch even when the resolved mode is " <>
                "\"off\"/\"never\"/\"disabled\"). Default false — normally such a dispatch is " <>
                "refused so we don't double-post an approval or ignore a hard opt-out."
          }
        },
        "required" => [],
        "additionalProperties" => false
      },
      handler: &Tools.worker_review/2
    },
    %{
      name: "worker_stop",
      tiers: @coordinator,
      description:
        "Stop the worker currently working a task (`arb worker stop`). Scoped to the coordinator's " <>
          "workspace; a task with no live worker is reported not-found. Teardown only — does not dispatch.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task whose worker to stop (required)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_stop/2
    },
    %{
      name: "message_send",
      tiers: @both,
      description:
        "Send a message to a task's mailbox (the structured replacement for `arb message <task> <text>`). " <>
          "A coordinator sends a direction from `coordinator`; a worker raises a flag from its own task " <>
          "to a sibling. The sender identity is set from the scope and pinned to its workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Recipient task id (required)."},
          "body" => %{"type" => "string", "description" => "Message body (required)."},
          "subject" => %{"type" => "string"},
          "kind" => %{
            "type" => "string",
            "enum" => ["notification", "completion", "failure", "escalation", "info"],
            "description" =>
              "Message kind (notification|completion|failure|escalation|info). " <>
                "Defaults to auto-derived kind based on scope (direction for coordinator, flag for worker)."
          },
          "task_ref" => %{
            "type" => "string",
            "description" =>
              "The task id this message concerns. Shown in brackets by `arb inbox`. " <>
                "Defaults to the recipient task_id."
          },
          "directive_ref" => %{
            "type" => "string",
            "description" => "Deprecated alias for task_ref. Ignored if task_ref is also given."
          }
        },
        "required" => ["task_id", "body"],
        "additionalProperties" => false
      },
      handler: &Tools.message_send/2
    },
    %{
      name: "notify_list",
      tiers: @both,
      description:
        "List the most recent notifications (completions, milestones, system events) for the workspace. " <>
          "Read-only; optional `limit` (default 20).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max notifications to return (default 20)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.notify_list/2
    },
    %{
      name: "worker_list",
      tiers: @coordinator,
      description:
        "List active workers in the workspace: task_id, registry_key, role, status, repo, " <>
          "started_at, activity, model (short display name e.g. \"Sonnet\"), cost_usd (sum " <>
          "of all ledger entries for the task), resumable (boolean: whether the task can be " <>
          "safely resumed), and blocked_reason (string or nil: human-readable reason if " <>
          "resumable is false). A task may have TWO rows: its own worker (registry_key == " <>
          "task_id, role null) plus a merge-queue subordinate pass (registry_key " <>
          "`<task_id>:fixpass` / `<task_id>:conflict`, role `fix_pass` / `conflict_resolver`) " <>
          "running while the primary is parked awaiting its merge. Check resumable before " <>
          "attempting to stop/resume: false indicates the task is blocked (e.g. awaiting " <>
          "merge queue or review gate) and cannot be safely touched. Never operate on a " <>
          "subordinate row (role is not null) — the merge queue owns those passes.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.worker_list/2
    },
    %{
      name: "worker_show",
      tiers: @coordinator,
      description:
        "Full snapshot for a single task's worker (`arb worker show <task-id>`): status, " <>
          "activity, and recent output lines. When a worker is currently live, returns its " <>
          "in-memory state (`source: \"live\"`); otherwise falls back to the most recent " <>
          "durable run row (`source: \"history\"`) so a finished/exited run stays inspectable. " <>
          "Not-found only when neither a live worker nor any run has ever been recorded.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task whose worker to inspect (required)."
          },
          "lines" => %{
            "type" => "integer",
            "description" =>
              "Optional: return only the last N output lines instead of the full history."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_show/2
    },
    %{
      name: "worker_runs",
      tiers: @coordinator,
      description:
        "List every historical run recorded for a task, newest first (`arb worker runs " <>
          "<task-id>`). Each entry is a run summary (no output lines — use `worker_log` for " <>
          "the transcript): id, task_id, task_title, repo, workspace_id, worker_type, status, " <>
          "model, started_at, completed_at, exit_code, failure_reason, failure_summary " <>
          "(a bounded human-readable ReviewGate VERDICT + top finding, when the run failed " <>
          "via a ReviewGate rejection; nil otherwise). Optional `limit` " <>
          "(default 20, max 200). `task_id` may be a ReviewGate synthetic id " <>
          "(`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`) — those aren't `issues` " <>
          "rows, but the run lookup still resolves (authorization checks the base task).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Task whose run history to list (required). Accepts a plain task id or a " <>
                "ReviewGate synthetic id such as `<base>#review`."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max runs to return (default 20, max 200)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_runs/2
    },
    %{
      name: "worker_log",
      tiers: @coordinator,
      description:
        "Full, uncapped durable transcript of one run — the audit source of record, " <>
          "retaining every line however long the run. Pass `run_id` to read that exact run " <>
          "(independent of which run is latest — the only way to reach a superseded/failed " <>
          "attempt), or `task_id` (no `run_id`) for the task's most recent run (`arb worker " <>
          "log <task-id>`, unchanged behaviour). `task_id` may be a ReviewGate synthetic id " <>
          "(`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`). `exists` distinguishes " <>
          "\"no file yet / never captured\" (false, empty `lines`) from \"captured but empty\" " <>
          "(true, empty `lines`). Not-found when no matching run exists.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Task whose latest run's transcript to read. Accepts a plain task id or a " <>
                "ReviewGate synthetic id such as `<base>#review`. Ignored when `run_id` is given."
          },
          "run_id" => %{
            "type" => "string",
            "description" =>
              "Exact run id whose transcript to read, independent of which run is latest " <>
                "for its task. Takes precedence over `task_id`."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_log/2
    },
    %{
      name: "worker_prompt",
      tiers: @coordinator,
      description:
        "The composed prompt one run was spawned with (bd-9rdwe4, #1017 gap G5), redacted " <>
          "through the same choke-point as transcript lines — the sibling of `worker_log` for " <>
          "\"what was this agent told\" instead of \"what did it say\". Pass `run_id` to read " <>
          "that exact run, or `task_id` (no `run_id`) for the task's most recent run. `task_id` " <>
          "may be a ReviewGate synthetic id (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, " <>
          "`#t<N>`). `exists` distinguishes \"no prompt ever persisted\" (false, `prompt` nil) " <>
          "from a captured (possibly empty-after-redaction) one. `prompt_sha256` mirrors the " <>
          "Run row's column so identical prompts are comparable without re-fetching the text. " <>
          "Not-found when no matching run exists.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Task whose latest run's prompt to read. Accepts a plain task id or a " <>
                "ReviewGate synthetic id such as `<base>#review`. Ignored when `run_id` is given."
          },
          "run_id" => %{
            "type" => "string",
            "description" =>
              "Exact run id whose prompt to read, independent of which run is latest for its " <>
                "task. Takes precedence over `task_id`."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_prompt/2
    },
    %{
      name: "run_log_list",
      tiers: @coordinator,
      description:
        "Enumerate every run recorded for a task AND its ReviewGate synthetic children " <>
          "(`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`), newest first — the " <>
          "whole retrievable transcript corpus for a task in one call. Unlike `worker_runs` " <>
          "(exact `task_id` match only), this also matches anything prefixed `<task_id>#`, " <>
          "surfacing the reviewer/re-prompt corpus alongside the author's own runs. Each " <>
          "entry: run_id, task_id, worker_type, status, model, started_at, " <>
          "transcript_exists, line_count. Optional `limit` (default 200, max 1000).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Base task whose full run corpus (including synthetic children) to list " <>
                "(required). Pass the plain task id even to reach synthetic runs."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max runs to return (default 200, max 1000)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.run_log_list/2
    },
    %{
      name: "transcript_capture_stats",
      tiers: @coordinator,
      description:
        "Transcript-capture health for a workspace (bd-9wotbo, gap G4): what fraction of " <>
          "Claude-driven runs actually produced a durable transcript. Scoped to " <>
          "`started_at >= 2026-06-20` (the arbiter-worker-logs corpus start date — earlier runs " <>
          "lived under the retired arbiter-polecat-logs root, an accepted, unreachable loss). " <>
          "Workflow-mode (bookkeeping-only) runs never open a Claude session, so they're reported " <>
          "separately as workflow_only_runs and excluded from claude_sessions / capture_rate_pct " <>
          "rather than counted as capture failures. Returns corpus_start_date, total_runs, " <>
          "claude_sessions, transcript_missing, workflow_only_runs, capture_rate_pct (nil when " <>
          "claude_sessions is 0). Optional `workspace` to target a workspace other than the default.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Workspace name/id to report on. Omit for the default workspace."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.transcript_capture_stats/2
    },
    %{
      name: "external_review_list",
      tiers: @coordinator,
      description:
        "List recent ExternalReview audit records for a workspace (bd-31fh9e). Returns in-flight " <>
          "and completed external PR reviews in reverse-chronological order. Each record carries the " <>
          "PR ref, verdict, finding count, model, cost, dispatched-by, and timestamps. Optional " <>
          "`limit` (default 20, max 200), `status` filter (`running` | `completed` | `failed`), and " <>
          "`workspace` to target a workspace other than the default.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max records to return (default 20, max 200)."
          },
          "status" => %{
            "type" => "string",
            "enum" => ["running", "completed", "failed"],
            "description" => "Filter by review status. Omit for all."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.external_review_list/2
    },
    %{
      name: "external_review_show",
      tiers: @coordinator,
      description:
        "Fetch a single ExternalReview record by `record_id`, including its full " <>
          "`proposed_comments` (file, line, severity, message, body) — the pre-greenlight read " <>
          "path for a report_only review (bd-dmy4pk). Workspace-agnostic: looked up directly by " <>
          "id, no workspace filter.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" => "ExternalReview record id to fetch (required)."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.external_review_show/2
    },
    %{
      name: "external_review_transcript",
      tiers: @coordinator,
      description:
        "Full durable corpus of one external review (bd-7efini): the composed prompt it was " <>
          "given, the raw stream-json transcript its reviewer emitted, and every tool call in " <>
          "that transcript paired with the result it returned. `worker_log`'s counterpart for a " <>
          "review — an external review is not task-linked, so it has no run row and can't be " <>
          "reached via `run_log_list`/`worker_log`; it is keyed on its own review record id. " <>
          "Returns record_id, pr_ref, path, prompt_path, exists, prompt_exists, prompt, " <>
          "line_count, lines, truncated, tool_use_count, tools_used, tool_uses. Workspace-" <>
          "agnostic, like `external_review_show`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" => "ExternalReview record id whose transcript to read (required)."
          },
          "tail" => %{
            "type" => "integer",
            "description" =>
              "Return only the last N transcript lines (`truncated: true` when lines were " <>
                "dropped). Omit for the whole transcript — a tool-heavy review runs to " <>
                "thousands of JSONL lines."
          },
          "include_prompt" => %{
            "type" => "boolean",
            "description" => "Set false to skip the (large) composed prompt. Default true."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.external_review_transcript/2
    },
    %{
      name: "review_gate_rounds_list",
      tiers: @coordinator,
      description:
        "List internal ReviewGate round outcomes for a task (bd-aqyjuc): one row per reviewer " <>
          "or implementer pass, oldest-first. Each row carries the round number, role " <>
          "(review/impl), verdict (approve/request_changes, nil for impl), findings text, " <>
          "finding count, the model that ran the pass, its cost, and whether it converged — " <>
          "so a round-1 rejection followed by a round-2 approval is visible as two distinct " <>
          "rows instead of collapsing into the task's terminal outcome. Backfill is out of " <>
          "scope; rows only exist for ReviewGate runs from 2026-07-28 onward.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task whose ReviewGate rounds to list (required)."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Cap the response to the most recent N rounds, still returned oldest-first " <>
                "(optional; omit for full history). `total_count` in the response always " <>
                "reports how many rounds exist."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.review_gate_rounds_list/2
    },
    %{
      name: "review_greenlight",
      tiers: @coordinator,
      description:
        "Greenlight a report-only (propose) review (bd-36qzgx): post the approved subset of a " <>
          "review's proposed comments to the PR under the fleet's identity — and nothing else. " <>
          "Requires a `can_dispatch` coordinator token. Pass `record_id` (from external_review_list; " <>
          "the review's `mode` must be `report_only`). `select` chooses which proposed comments post: " <>
          "omit or \"all\" for every comment, a list of zero-based indices for a subset, or [] to " <>
          "approve nothing (a true no-op on the PR). `post_verdict` also submits the recommended " <>
          "verdict (defaults on when ≥1 comment is approved).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" =>
              "ExternalReview record id of the report-only review to greenlight (required)."
          },
          "select" => %{
            "oneOf" => [
              %{"type" => "string", "enum" => ["all"]},
              %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 0}}
            ],
            "description" =>
              "Which proposed comments to post: \"all\" (default), a list of zero-based indices, or [] for none."
          },
          "post_verdict" => %{
            "type" => "boolean",
            "description" =>
              "Also submit the recommended verdict as a single review. Defaults on iff ≥1 comment is approved."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "Local checkout (only needed by adapters resolving owner/repo for a bare PR number)."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.review_greenlight/2
    },
    %{
      name: "task_list",
      tiers: @coordinator,
      description:
        "List tasks in the workspace with optional filters. `status` (open | in_progress | closed), " <>
          "`priority` (integer 0–4), and `issue_type` (task | bug | feature | epic | chore | decision) " <>
          "are all optional. Returns matching tasks in the coordinator's workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "status" => %{
            "type" => "string",
            "description" => "Filter by status: open | in_progress | closed."
          },
          "priority" => %{
            "type" => "integer",
            "description" => "Filter by priority (0 = highest, 4 = lowest)."
          },
          "issue_type" => %{
            "type" => "string",
            "description" => "Filter by type: task | bug | feature | epic | chore | decision."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_list/2
    },
    %{
      name: "tracker_claim",
      tiers: @coordinator,
      description:
        "Claim an external tracker issue into a task (`arb claim <issue#>`). Verifies the issue is " <>
          "assigned to the workspace user (skip with `force: true`) and creates a linked task. " <>
          "Idempotent — returns the existing task if one already references the issue.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ref" => %{
            "type" => "string",
            "description" => "Tracker issue ref / number (required)."
          },
          "force" => %{
            "type" => "boolean",
            "description" => "Skip the assignment-as-claim check (default false)."
          }
        },
        "required" => ["ref"],
        "additionalProperties" => false
      },
      handler: &Tools.tracker_claim/2
    },
    %{
      name: "tracker_sync",
      tiers: @coordinator,
      description:
        "Reconcile the workspace's tasks against its external tracker (`arb sync`): open assigned " <>
          "issues with no task get a linked task; open tasks whose issue is closed upstream or " <>
          "reassigned away get closed (unassigned issues are left alone); closed tasks whose close was " <>
          "meant to propagate upstream — a recorded close intent, or for rows closed before that was " <>
          "recorded a non-blank `pr_ref` — but whose tracker issue is still open are reported as `drift` " <>
          "(a close that never propagated upstream — drift entries are report-only and never mutate the " <>
          "local task). `task`-type and `review_only` tasks are exempt: they are expected to close with " <>
          "their ticket still open. `dry: true` returns the plan without acting. No-ops cleanly when the " <>
          "tracker does not support reconciliation.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "dry" => %{
            "type" => "boolean",
            "description" => "Return the plan without applying it (default false)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.tracker_sync/2
    },
    %{
      name: "workspace_list",
      tiers: @coordinator,
      description:
        "List the configured workspaces (id, name, prefix, tracker type) — the discovery surface for " <>
          "which workspaces exist. Summary fields only; full config + security posture stay behind " <>
          "`workspace_show` for the bound workspace.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_list/2
    },
    %{
      name: "workspace_config_get",
      tiers: @both,
      description:
        "Read a dotted.key (e.g. \"merge.auto_merge\") or the full config for a named workspace. " <>
          "Secret *values* are never returned — only `secret_keys` (the names of configured secrets) " <>
          "and any `credentials_ref` pointers already embedded in the config JSON. " <>
          "Returns `{workspace, key, value, secret_keys}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Dotted config key to read (e.g. \"merge.auto_merge\"). Omit to return the full config."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_get/2
    },
    %{
      name: "workspace_config_overview",
      tiers: @both,
      description:
        "A human-readable grouped summary of the workspace config: tracker, merge, agent, " <>
          "review_agent, routing, review, review_gate, standing_orders, and the names of configured " <>
          "secrets (values never exposed). Mirrors `arb config overview`. " <>
          "Returns `{workspace, tracker, merge, agent, …, secret_keys}`.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_config_overview/2
    },
    %{
      name: "workspace_config_set",
      tiers: @coordinator,
      description:
        "Set a single dotted.key to a value via the deep-merge config endpoint, preserving all " <>
          "sibling keys. Secret / credential key prefixes are blocked — use `arb workspace secret` " <>
          "for secrets. Returns `{workspace, config, secret_keys}` after the merge so the caller " <>
          "can confirm the result.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "Dotted config key to set (e.g. \"merge.auto_merge\"). Required."
          },
          "value" => %{
            "oneOf" => [
              %{"type" => "boolean"},
              %{"type" => "integer"},
              %{"type" => "number"},
              %{"type" => "string"},
              %{"type" => "object"},
              %{"type" => "array"},
              %{"type" => "null"}
            ],
            "description" =>
              "Value to assign. Accepts any JSON type: boolean, integer, string, object, array, " <>
                "or null. Pass a real JSON array/object for list/nested keys (e.g. " <>
                "[\"claude\", \"gemini\"]) — do NOT pass a JSON-encoded string."
          }
        },
        "required" => ["key", "value"],
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_set/2
    },
    %{
      name: "workspace_config_unset",
      tiers: @coordinator,
      description:
        "Remove a single dotted.key from the config via the deep-merge endpoint, preserving all " <>
          "sibling keys. Errors if the key does not exist. Secret / credential key prefixes are " <>
          "blocked. Returns `{workspace, config, secret_keys}` after the removal.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Dotted config key to remove (e.g. \"agent.config.vernacular\"). Required."
          }
        },
        "required" => ["key"],
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_unset/2
    },
    %{
      name: "installation_config_get",
      tiers: @both,
      description:
        "Read an install-wide runtime setting (not workspace-scoped): " <>
          "`conductor_system_max_concurrent` (the Conductor's system-wide concurrency ceiling), " <>
          "`credential_watchdog_adapters`, `credential_watchdog_interval_ms`, " <>
          "`credential_watchdog_recovery_interval_ms`. " <>
          "Omit `key` to get the full settings map. Returns `{key, value, settings}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "enum" => [
              "conductor_system_max_concurrent",
              "credential_watchdog_adapters",
              "credential_watchdog_interval_ms",
              "credential_watchdog_recovery_interval_ms"
            ],
            "description" =>
              "Setting name (e.g. \"conductor_system_max_concurrent\"). Omit for all settings."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.installation_config_get/2
    },
    %{
      name: "installation_config_set",
      tiers: @coordinator,
      description:
        "Set an install-wide runtime setting; `null` always clears the override and falls back " <>
          "to the app-env/hardcoded default. `conductor_system_max_concurrent` (positive " <>
          "integer) takes effect on the next Conductor drain cycle across every running graph. " <>
          "`credential_watchdog_adapters` (list of agent types — \"claude\", \"gemini\", " <>
          "\"codex\"; `[]` probes nothing), `credential_watchdog_interval_ms` and " <>
          "`credential_watchdog_recovery_interval_ms` (positive integers) take effect on the " <>
          "CredentialWatchdog's next poll cycle. No restart required. Returns `{key, value}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "enum" => [
              "conductor_system_max_concurrent",
              "credential_watchdog_adapters",
              "credential_watchdog_interval_ms",
              "credential_watchdog_recovery_interval_ms"
            ],
            "description" => "Setting name (e.g. \"conductor_system_max_concurrent\"). Required."
          },
          "value" => %{
            "description" =>
              "Positive integer (or, for credential_watchdog_adapters, a list of agent-type " <>
                "strings), or null to clear the override.",
            "oneOf" => [
              %{
                "type" => "null",
                "description" => "Clear the override and fall back to default."
              },
              %{
                "type" => "integer",
                "minimum" => 1,
                "description" =>
                  "Positive integer for conductor_system_max_concurrent, " <>
                    "credential_watchdog_interval_ms, or credential_watchdog_recovery_interval_ms."
              },
              %{
                "type" => "array",
                "items" => %{
                  "type" => "string",
                  "enum" => ["claude", "gemini", "codex"]
                },
                "description" =>
                  "List of agent type strings for credential_watchdog_adapters (e.g., [\"claude\", \"gemini\"])."
              }
            ]
          }
        },
        "required" => ["key", "value"],
        "additionalProperties" => false
      },
      handler: &Tools.installation_config_set/2
    },
    %{
      name: "skill_create",
      tiers: @coordinator,
      description:
        "Create a skill (a reusable markdown instruction module arbiter materializes into a " <>
          "worker's worktree). Scope with the optional `workspace` arg: omit it for a GLOBAL " <>
          "skill shared by every workspace (default), or name a workspace to create a " <>
          "workspace-scoped skill that shadows a same-named global there. `name` (unique " <>
          "within the scope, kebab-case) and `body` (markdown) are required; optional " <>
          "`metadata` object, `activation_mode` (always_on|situational, default situational), " <>
          "and `code_only` (bool, default false). The paper-trail version records the calling " <>
          "actor. Returns the created skill (with `scope`/`workspace_id`), plus a non-fatal " <>
          "`warning` when the name collides with a bundled skill.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Unique kebab-case name; the /<name> slash command. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) to scope the skill to. Omit for a global skill."
          },
          "body" => %{
            "type" => "string",
            "description" => "Markdown skill body (the SKILL.md contents). Required."
          },
          "metadata" => %{
            "type" => "object",
            "description" => "Optional free-form metadata (e.g. description, tags)."
          },
          "activation_mode" => %{
            "type" => "string",
            "enum" => ["situational", "always_on"],
            "description" =>
              "always_on = arbiter auto-invokes /<name> in every worker prompt where the " <>
                "skill applies; situational = advertised only, agent decides. Default situational."
          },
          "code_only" => %{
            "type" => "boolean",
            "description" =>
              "When true, the skill only applies to code-producing tasks (feature/bug/chore); " <>
                "excluded from decision/task/epic. Default false."
          }
        },
        "required" => ["name", "body"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_create/2
    },
    %{
      name: "skill_update",
      tiers: @coordinator,
      description:
        "Update a skill identified by `skill` (its id, or its name resolved within the " <>
          "`workspace` scope with a scoped skill shadowing the global). Any subset of " <>
          "`name` / `body` / `metadata` / `activation_mode` / `code_only` may be supplied; a " <>
          "skill's workspace scope is fixed at creation and cannot be changed here. The " <>
          "prior `body` is preserved as a paper-trail version (restorable), and the version " <>
          "records the calling actor. Returns the updated skill, plus a non-fatal `warning` " <>
          "when the (new) name collides with a bundled skill.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to update. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) that scopes a name lookup. Omit to target a global skill."
          },
          "name" => %{"type" => "string", "description" => "New kebab-case name (optional)."},
          "body" => %{"type" => "string", "description" => "New markdown body (optional)."},
          "metadata" => %{"type" => "object", "description" => "Replacement metadata (optional)."},
          "activation_mode" => %{
            "type" => "string",
            "enum" => ["situational", "always_on"],
            "description" =>
              "always_on auto-invokes /<name>; situational advertises only (optional)."
          },
          "code_only" => %{
            "type" => "boolean",
            "description" => "Restrict the skill to code-producing tasks (optional)."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_update/2
    },
    %{
      name: "skill_delete",
      tiers: @coordinator,
      description:
        "Delete a system-wide skill identified by `skill` (its id or name). " <>
          "Returns `{deleted: true, id, name}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to delete. Required."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_delete/2
    },
    %{
      name: "skill_list",
      tiers: @both,
      description:
        "List skills (name, scope/workspace_id, metadata, activation_mode, code_only — no " <>
          "`body`), ordered by name. Scoped to what the caller may see: a worker sees its " <>
          "own workspace's effective set (globals overlaid by that workspace's scoped " <>
          "skills, scoped winning on a name clash); a coordinator sees every skill, or the " <>
          "effective set for a given `workspace`. Same registry as " <>
          "`skill_create`/materialization; use `skill_get` to fetch a body.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) to list the effective set for. Coordinator " <>
                "only; a worker is always scoped to its own workspace."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.skill_list/2
    },
    %{
      name: "skill_get",
      tiers: @both,
      description:
        "Fetch one skill's full markdown body by `skill` (its id, or its name resolved " <>
          "within the caller's workspace scope — a workspace-scoped skill shadows the " <>
          "global). A worker may only read a global skill or one scoped to its own " <>
          "workspace; a coordinator may read any, or scope a name lookup with `workspace`. " <>
          "Lets the coordinator (not worktree-isolated, so it can't rely on materialization) " <>
          "or any agent pull a skill body on demand from the same registry.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to fetch. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) that scopes a name lookup. Coordinator only."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_get/2
    },
    # ---- the Stage 2 loop-proposal queue (bd-9j2g3x) -----------------------
    #
    # Coordinator-only, every one of them. A fleet-wide skill patch or config
    # change is not a worker's call, and a worker bound to one task must never be
    # able to apply a write whose blast radius is the whole fleet.
    %{
      name: "loop_pending_list",
      tiers: @coordinator,
      description:
        "List queued loop-engineering proposals produced by `arb loop analyze --propose`. " <>
          "Optional `state` (one name or a list; defaults to the live states `hypothesis` + " <>
          "`proposed`), `kind`, `workspace`, `limit`. A `hypothesis` is a finding below the " <>
          "evidence bar kept with its incident refs so later windows reinforce it in place; " <>
          "crossing the bar promotes it to `proposed`. Returns summaries (no diffs) plus the " <>
          "workspace's `evidence_bar`; use `loop_pending_diff` to read one in full.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "oneOf" => [
              %{"type" => "string", "enum" => @loop_states},
              %{"type" => "array", "items" => %{"type" => "string", "enum" => @loop_states}}
            ],
            "description" =>
              "Optional state filter: one name or a list. Defaults to hypothesis + proposed."
          },
          "kind" => %{
            "type" => "string",
            "enum" => @loop_kinds,
            "description" => "Optional kind filter."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) to scope the list to."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Optional cap on rows returned, newest first."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_list/2
    },
    %{
      name: "loop_pending_diff",
      tiers: @coordinator,
      description:
        "Read one queued loop proposal in full by `id`: its unified `diff`, `payload`, " <>
          "pre-registered `target_metric` / `baseline`, accumulated `incident_refs` / " <>
          "`task_refs`, and — when it is not applicable yet — `inapplicable_reason` naming " <>
          "the current evidence and what is still missing. Read this before applying.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id. Required."},
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_diff/2
    },
    %{
      name: "loop_pending_apply",
      tiers: @coordinator,
      description:
        "Apply the queued loop proposal `id`. Coordinator only — a worker must never apply a " <>
          "fleet-wide change. Dispatches on `kind` to the same public domain API a human " <>
          "would call (`Arbiter.Skills.update_skill/2`, the workspace config deep-merge, an " <>
          "Issue update), so the write lands with a normal paper-trail version attributed to " <>
          "the proposal id. Refuses anything that is not `proposed`; a `hypothesis` reply " <>
          "names its evidence count and the shortfall. Nothing is ever applied " <>
          "automatically — this tool is the only apply path.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id to apply. Required."},
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_apply/2
    },
    %{
      name: "loop_pending_reject",
      tiers: @coordinator,
      description:
        "Soft-reject the queued loop proposal `id` with an optional `reason`. The row " <>
          "persists as `rejected` (never deleted), so later windows reinforce its evidence " <>
          "in place rather than re-proposing the same finding from scratch — but it does not " <>
          "re-open on its own.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id to reject. Required."},
          "reason" => %{
            "type" => "string",
            "description" => "Optional reason, recorded on the row."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_reject/2
    },
    %{
      name: "usage_summarize",
      tiers: @coordinator,
      description:
        "Roll up the token/cost usage ledger for the workspace. `by` is required (day, task, " <>
          "epic, workspace, repo, model, step, provider — `campaign` also accepted as a " <>
          "deprecated alias for `epic`); optional `since` (ISO-8601) and `limit`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "by" => %{"type" => "string", "description" => "Grouping dimension (required)."},
          "since" => %{
            "type" => "string",
            "description" => "ISO-8601 datetime lower bound (optional)."
          },
          "limit" => %{"type" => "integer", "description" => "Cap the returned rows (optional)."}
        },
        "required" => ["by"],
        "additionalProperties" => false
      },
      handler: &Tools.usage_summarize/2
    },

    # ---- C7: graph CRUD + lifecycle -----------------------------------------
    %{
      name: "graph_create",
      tiers: @coordinator,
      description:
        "Create a Graph in the workspace. `name` is required; optional `description`. " <>
          "A Graph is an execution unit: a named set of directives run together.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Graph name (required)."},
          "description" => %{"type" => "string", "description" => "Markdown summary (optional)."}
        },
        "required" => ["name"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_create/2
    },
    %{
      name: "graph_add_directive",
      tiers: @coordinator,
      description:
        "Add a directive (Issue) to a Graph as a member. " <>
          "Directives must be in the same workspace as the graph. " <>
          "In a workspace with more than one configured repo, pass `repo` so the " <>
          "Conductor can auto-dispatch this directive when it becomes ready — " <>
          "without it, dispatch falls back to the workspace's `default_repo` config " <>
          "(if set via workspace_config_set) or else fails with `ambiguous_repo` and " <>
          "the directive stays `ready` forever.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."},
          "issue_id" => %{
            "type" => "string",
            "description" => "Directive (task) id (required)."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "Repo this directive dispatches into (optional). Required for auto-dispatch " <>
                "to succeed in a workspace with more than one configured repo; auto-resolves " <>
                "when the workspace has exactly one."
          }
        },
        "required" => ["graph_id", "issue_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_add_directive/2
    },
    %{
      name: "graph_remove_directive",
      tiers: @coordinator,
      description:
        "Remove a directive (Issue) from a Graph. Idempotent — returns `removed: 0` " <>
          "when the directive is not a member.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."},
          "issue_id" => %{"type" => "string", "description" => "Directive (task) id (required)."}
        },
        "required" => ["graph_id", "issue_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_remove_directive/2
    },
    %{
      name: "graph_add_edge",
      tiers: @coordinator,
      description:
        "Add a dependency edge between two directives in a Graph. " <>
          "`type` must be one of `depends_on`, `blocks`, or `conflicts_with`. " <>
          "`depends_on` and `blocks` gate execution order; `conflicts_with` prevents " <>
          "co-dispatch (symmetric mutex, non-gating). Both directives must be in the " <>
          "graph's workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."},
          "from_issue_id" => %{
            "type" => "string",
            "description" => "The dependent directive (required)."
          },
          "to_issue_id" => %{
            "type" => "string",
            "description" => "The dependency target (required)."
          },
          "type" => %{
            "type" => "string",
            "enum" => ["depends_on", "blocks", "conflicts_with"],
            "description" => "Edge type (required)."
          },
          "notes" => %{"type" => "string", "description" => "Markdown context (optional)."}
        },
        "required" => ["graph_id", "from_issue_id", "to_issue_id", "type"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_add_edge/2
    },
    %{
      name: "graph_start",
      tiers: @coordinator,
      description:
        "Start a Graph: validate acyclicity, transition `:draft → :running`, and start " <>
          "the Conductor which dispatches ready directives. Rejects cyclic graphs with the " <>
          "named cycle. The graph must be in `:draft` state.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."}
        },
        "required" => ["graph_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_start/2
    },
    %{
      name: "graph_pause",
      tiers: @coordinator,
      description:
        "Pause a running Graph: transition `:running → :paused` and stop the Conductor. " <>
          "Workers already dispatched continue to completion; no new dispatches occur " <>
          "while paused. Resume with `graph_resume`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."}
        },
        "required" => ["graph_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_pause/2
    },
    %{
      name: "graph_resume",
      tiers: @coordinator,
      description:
        "Resume a paused Graph: transition `:paused → :running` and restart the Conductor " <>
          "to continue dispatching ready directives. The graph must be in `:paused` state.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."}
        },
        "required" => ["graph_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_resume/2
    },
    %{
      name: "graph_status",
      tiers: @coordinator,
      description:
        "Return the run_state and running/ready/blocked/paused/failed/closed breakdown " <>
          "of a Graph's member directives. `paused` and `failed` counts come from the " <>
          "live Conductor (C5 failure handling) and are 0 when no Conductor is running.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "graph_id" => %{"type" => "string", "description" => "Graph id (required)."}
        },
        "required" => ["graph_id"],
        "additionalProperties" => false
      },
      handler: &Tools.graph_status/2
    },

    # ---- board scheduler (autopilot) pause/resume --------------------------
    %{
      name: "scheduler_pause",
      tiers: @coordinator,
      description:
        "Pause the board scheduler (autopilot): stop promoting Ready cards to Running. " <>
          "Workers already dispatched continue to completion; no new dispatches occur " <>
          "while paused. Resume with `scheduler_resume`. Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_pause/2
    },
    %{
      name: "scheduler_resume",
      tiers: @coordinator,
      description:
        "Resume the board scheduler (autopilot): start promoting Ready cards to Running again. " <>
          "Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_resume/2
    },
    %{
      name: "scheduler_status",
      tiers: @coordinator,
      description:
        "Return the current pause state of the board scheduler (autopilot). " <>
          "Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_status/2
    },

    # ---- C5: queue resume ---------------------------------------------------
    %{
      name: "queue_resume",
      tiers: @coordinator,
      description:
        "Resume a paused graph branch by re-dispatching the failed task that blocked it " <>
          "(C5 of #482). Searches all running Conductors for one that has `task_id` in its " <>
          "failed set and re-dispatches it, unblocking the downstream branch. " <>
          "Use after receiving a conductor failure escalation in the coordinator inbox.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "The failed task ID to re-dispatch (required)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.queue_resume/2
    },
    %{
      name: "queue_retry_auto_resolve",
      tiers: @coordinator,
      description:
        "Re-arm one more auto-resolve attempt on a task's merge Watchdog after it has " <>
          "exhausted max_auto_resolve_attempts on a :ci_failed block and parked indefinitely " <>
          "(bd-bspakl). Bumps this episode's budget by exactly one attempt; the next " <>
          "watchdog poll (within its poll interval) dispatches a fresh fix-pass worker if " <>
          "the block is still ci_failed. Use after an 'auto-resolve exhausted' escalation " <>
          "in the coordinator inbox, when you've confirmed a fresh fix-pass is worth trying.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "The parked task ID to re-arm (required)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.queue_retry_auto_resolve/2
    },
    %{
      name: "queue_restart_watchdog",
      tiers: @coordinator,
      description:
        "Mint a FRESH merge Watchdog for a task whose Watchdog has died, attached to the MR " <>
          "its worker already has open (bd-8jixav). A Watchdog is a temporary process: when " <>
          "it crashes it is gone for good, silently, and the task sits at awaiting_review " <>
          "with an open MR nobody is polling. Use this when a parked task shows 'no watchdog " <>
          "running', or when queue_retry_auto_resolve answered 'no merge watchdog is " <>
          "currently running' on a task whose PR is genuinely still open. Refused if a " <>
          "watchdog is already running (two on one MR would race the merge). Much cheaper " <>
          "than worker_resume, which restarts the review gate from round 1.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "The task whose parked worker needs a new watchdog (required). Its worker must " <>
                "be alive and parked at awaiting_review."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.queue_restart_watchdog/2
    },
    %{
      name: "repo_list",
      tiers: @coordinator,
      description:
        "List registered repos with their paths, sources, active worker counts, and git worktree counts. " <>
          "Repos are discovered from workspace repo_paths configs, the application-env fallback, " <>
          "and any repos active workers are using. Mirrors `arb repo list`.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.repo_list/2
    },
    %{
      name: "repo_show",
      tiers: @coordinator,
      description:
        "Show details for a single repo: path, source, active worker count, and git worktree count. " <>
          "Returns not-found if the repo name does not exist.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Repo name (required)."
          }
        },
        "required" => ["name"],
        "additionalProperties" => false
      },
      handler: &Tools.repo_show/2
    }
  ]

  # Inject the optional `workspace` field into every tool that calls resolve_workspace_id,
  # so callers can target a workspace explicitly without each tool restating the property by hand.
  @tools Enum.map(@raw_tools, fn tool ->
           if tool.name in @workspace_tools do
             update_in(tool, [:input_schema, "properties"], fn props ->
               Map.put(props, "workspace", @workspace_field)
             end)
           else
             tool
           end
         end)

  @doc "All Phase 1 tool definitions, regardless of tier."
  @spec all() :: [tool()]
  def all, do: @tools

  @doc "The tool definitions visible to `scope` (those whose `:tiers` include the scope's tier)."
  @spec visible(Scope.t()) :: [tool()]
  def visible(%Scope{tier: tier}), do: Enum.filter(@tools, &(tier in &1.tiers))

  @doc "Look up a tool definition by name."
  @spec fetch(String.t()) :: {:ok, tool()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc """
  Authorize and execute a `tools/call`. Returns a normalized result the transport
  renders:

    * `{:ok, data}` — success (→ a tool result with `structuredContent`);
    * `{:rpc_error, code, message}` — unknown tool, or a scope/tier violation
      (→ a JSON-RPC error object, never a transport error);
    * `{:tool_error, message}` — an operational failure such as not-found or bad
      arguments (→ a tool result with `isError: true`).
  """
  @spec call(Scope.t(), String.t(), map()) :: call_result()
  def call(%Scope{} = scope, name, arguments) when is_binary(name) do
    args = if is_map(arguments), do: arguments, else: %{}

    case fetch(name) do
      :error ->
        {:rpc_error, @code_invalid_params, "Unknown tool: #{name}"}

      {:ok, tool} ->
        if scope.tier in tool.tiers do
          run(tool, scope, args)
        else
          {:rpc_error, @code_not_permitted,
           "Tool #{name} is not permitted for a #{scope.tier} scope"}
        end
    end
  end

  defp run(tool, scope, args) do
    case tool.handler.(scope, args) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, {:unauthorized, msg}} -> {:rpc_error, @code_not_permitted, msg}
      {:error, {_kind, msg}} when is_binary(msg) -> {:tool_error, msg}
    end
  rescue
    e -> {:tool_error, "tool #{tool.name} failed: #{Exception.message(e)}"}
  end
end
