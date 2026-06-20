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
  | `coordinator_inbox` | coordinator | `Messages.inbox/2` + `mark_read` (Admiral mailbox) |
  | `workspace_show` | worker, coordinator | `Ash.get(Workspace, id)` |
  | `task_update_progress` | worker, coordinator | `Ash.update(issue, …, action: :update)` |

  ## Phase 2 catalog (coordinator tools + the both-tier `message_send`)

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `task_create` | coordinator | `Ash.create(Issue, …)` |
  | `task_update` | coordinator | `Ash.update(issue, …, action: :update)` |
  | `task_close` | coordinator | `Ash.update(issue, …, action: :close)` |
  | `task_reopen` | coordinator | `Ash.update(issue, …, action: :reopen)` |
  | `dep_add` | coordinator | `Ash.create(Dependency, …)` (use `parent_of` to attach a child) |
  | `dep_remove` | coordinator | `Ash.destroy(Dependency)` |
  | `worker_dispatch` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` |
  | `worker_resume` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.resume/2` |
  | `worker_review` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` (`review: true`) |
  | `worker_stop` | coordinator | `Arbiter.Worker.stop/2` |
  | `worker_list` | coordinator | `Arbiter.Worker.list_children/0` |
  | `message_send` | worker, coordinator | `Messages.send_mail/1` (flag / direction) |
  | `notify_list` | worker, coordinator | `Messages.recent_notifications/2` |
  | `task_list` | coordinator | `Ash.read(Issue, …)` with filters |
  | `tracker_claim` | coordinator | `Arbiter.Tasks.Claim.claim/3` |
  | `tracker_sync` | coordinator | `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2` |
  | `workspace_list` | coordinator | `Ash.read(Workspace)` (summary fields) |
  | `usage_summarize` | coordinator | `Arbiter.Usage.summarize/1` |
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

  # Tools that do NOT take a `workspace` arg: `workspace_list` already enumerates
  # every workspace.
  @no_workspace_field ~w(workspace_list)

  @raw_tools [
    %{
      name: "task_show",
      tiers: @both,
      description:
        "Read one task (id, title, status, notes, tracker, `auto_close`, and child-progress " <>
          "`child_closed`/`child_total` over its `parent_of` children, …). A worker reads its " <>
          "own task (the `id` argument may be omitted); a coordinator must pass the `id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Task id (e.g. \"bd-dem49g\"). Optional for a worker (defaults to its own task)."
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
        "Read (and mark read) the unread mailbox for a task — the structured replacement for " <>
          "`arb inbox`. A worker checks its own task; a coordinator passes `task_id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Recipient task id. Optional for a worker (defaults to its own task)."
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
        "Read (and mark read) the Admiral escalation mailbox for the workspace — the structured " <>
          "replacement for `arb message inbox` / `arb inbox`. Lists all unread messages where " <>
          "`to_ref == \"admiral\"` and marks them read, so the dashboard unread count drops to 0. " <>
          "Optional `clear: true` also destroys the already-read tail (mirrors `arb inbox clear`). " <>
          "Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "clear" => %{
            "type" => "boolean",
            "description" =>
              "Also destroy the already-read tail after listing (mirrors `arb inbox clear`). Default false."
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
          "`tracker_type`, …. The task is always created in the coordinator's own workspace.",
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
            "description" => "none | jira | shortcut | linear | github."
          },
          "tracker_ref" => %{"type" => "string"},
          "target_branch" => %{"type" => "string"}
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
          "pr_ref" => %{"type" => "string"},
          "target_branch" => %{"type" => "string"}
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
        "Close a task in the workspace. Optional `reason`; `close_upstream: true` also closes the " <>
          "linked external tracker issue.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Task id (required)."},
          "reason" => %{"type" => "string"},
          "close_upstream" => %{
            "type" => "boolean",
            "description" => "Also close the linked tracker issue (default false)."
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
          "token and is depth-limited (the dispatch-recursion guardrail). Pass `provider` to start a " <>
          "worker session (`claude` or `gemini`); omit it to park the task in_progress.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task to dispatch (required)."},
          "repo" => %{"type" => "string", "description" => "Repo to run in (optional)."},
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "provider" => %{
            "type" => "string",
            "enum" => ["claude", "gemini"],
            "description" =>
              "Worker provider to dispatch. Omit to park the task in_progress (no worker)."
          },
          "with_claude" => %{
            "type" => "boolean",
            "description" =>
              "DEPRECATED alias for `provider: \"claude\"`. `true` → start a Claude worker."
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
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."}
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
        "Dispatch a review-only worker against the PR/MR linked to a task (`arb review`): no worktree, " <>
          "no branch, no merge. Requires a `can_dispatch` coordinator token and is depth-limited. " <>
          "Claude-driven by default; pass `with_claude: false` to dispatch without spawning an agent.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task to review (required)."},
          "repo" => %{
            "type" => "string",
            "description" => "Local checkout the reviewer runs in (needs `gh`/`git`)."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "with_claude" => %{
            "type" => "boolean",
            "description" => "Spawn the reviewer agent (default true)."
          }
        },
        "required" => ["task_id"],
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
          "subject" => %{"type" => "string"}
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
        "List active workers in the workspace: task_id, status, repo, started_at, activity, " <>
          "model (short display name e.g. \"Sonnet\"), and cost_usd (sum of all ledger entries for the task).",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.worker_list/2
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
        "Reconcile the workspace's tasks against its external tracker (`arb sync`): task assigned issues " <>
          "with no task, close tasks whose issue is gone. `dry: true` returns the plan without acting. " <>
          "No-ops cleanly when the tracker does not support reconciliation.",
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
      name: "usage_summarize",
      tiers: @coordinator,
      description:
        "Roll up the token/cost usage ledger for the workspace. `by` is required (day, task, " <>
          "campaign, workspace, repo, model, step, provider); optional `since` (ISO-8601) and `limit`.",
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
    }
  ]

  # Inject the optional `workspace` field into every workspace-resolving tool's
  # input schema (all but `@no_workspace_field`), so callers can target a
  # workspace explicitly without each tool restating the property by hand.
  @tools Enum.map(@raw_tools, fn tool ->
           if tool.name in @no_workspace_field do
             tool
           else
             update_in(tool, [:input_schema, "properties"], fn props ->
               Map.put(props, "workspace", @workspace_field)
             end)
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
