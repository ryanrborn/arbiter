defmodule Arbiter.MCP.Catalog do
  @moduledoc """
  The `Arbiter.MCP` tool catalog: the declarative list of Phase 1 tools (name,
  the tiers that may call each, a one-line description, and a JSON Schema for the
  inputs) plus the dispatch path that the transport (`ArbiterWeb.MCP.Plug`) drives
  for `tools/list` and `tools/call`.

  Tier-level visibility is the **only** capability decision made here: a tool is
  visible to — and callable by — a scope iff the scope's tier is in the tool's
  `:tiers`. Data-level rules (own-bead, workspace isolation) live in the handlers
  (`Arbiter.MCP.Tools`) via `Arbiter.MCP.Scope`.

  ## Phase 1 catalog

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `bead_show` | polecat, coordinator | `Ash.get(Issue, id)` + child-progress calcs |
  | `bead_ready` | coordinator | `Issue.ready/1` |
  | `inbox_check` | polecat, coordinator | `Messages.inbox/2` + `mark_read` |
  | `coordinator_inbox` | coordinator | `Messages.inbox/2` + `mark_read` (Admiral mailbox) |
  | `workspace_show` | polecat, coordinator | `Ash.get(Workspace, id)` |
  | `bead_update_progress` | polecat, coordinator | `Ash.update(issue, …, action: :update)` |

  ## Phase 2 catalog (coordinator tools + the both-tier `message_send`)

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `bead_create` | coordinator | `Ash.create(Issue, …)` |
  | `bead_update` | coordinator | `Ash.update(issue, …, action: :update)` |
  | `bead_close` | coordinator | `Ash.update(issue, …, action: :close)` |
  | `bead_reopen` | coordinator | `Ash.update(issue, …, action: :reopen)` |
  | `dep_add` | coordinator | `Ash.create(Dependency, …)` (use `parent_of` to attach a child) |
  | `dep_remove` | coordinator | `Ash.destroy(Dependency)` |
  | `polecat_sling` | coordinator (`can_sling`) | `Arbiter.Polecat.Sling.sling/2` |
  | `polecat_resume` | coordinator (`can_sling`) | `Arbiter.Polecat.Sling.resume/2` |
  | `polecat_review` | coordinator (`can_sling`) | `Arbiter.Polecat.Sling.sling/2` (`review: true`) |
  | `polecat_stop` | coordinator | `Arbiter.Polecat.stop/2` |
  | `polecat_list` | coordinator | `Arbiter.Polecat.list_children/0` |
  | `message_send` | polecat, coordinator | `Messages.send_mail/1` (flag / direction) |
  | `notify_list` | polecat, coordinator | `Messages.recent_notifications/2` |
  | `bead_list` | coordinator | `Ash.read(Issue, …)` with filters |
  | `tracker_claim` | coordinator | `Arbiter.Beads.Claim.claim/3` |
  | `tracker_sync` | coordinator | `Arbiter.Beads.Claim.plan/1` + `apply_plan/2` |
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

  @both [:polecat, :coordinator]
  @coordinator [:coordinator]

  @tools [
    %{
      name: "bead_show",
      tiers: @both,
      description:
        "Read one bead (id, title, status, notes, tracker, `auto_close`, and child-progress " <>
          "`child_closed`/`child_total` over its `parent_of` children, …). A polecat reads its " <>
          "own bead (the `id` argument may be omitted); a coordinator must pass the `id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Bead id (e.g. \"bd-dem49g\"). Optional for a polecat (defaults to its own bead)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.bead_show/2
    },
    %{
      name: "bead_ready",
      tiers: [:coordinator],
      description: "List ready (open, unblocked) beads in the workspace.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.bead_ready/2
    },
    %{
      name: "inbox_check",
      tiers: @both,
      description:
        "Read (and mark read) the unread mailbox for a bead — the structured replacement for " <>
          "`arb inbox`. A polecat checks its own bead; a coordinator passes `bead_id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{
            "type" => "string",
            "description" =>
              "Recipient bead id. Optional for a polecat (defaults to its own bead)."
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
      name: "bead_update_progress",
      tiers: @both,
      description:
        "Record progress / completion notes on a bead — `notes`, `qa_notes`, `deployment_notes`, " <>
          "`pr_body` only (the structured replacement for `arb issue update --qa-notes …`). A " <>
          "polecat may only update its own bead and cannot change status or priority.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Bead id. Optional for a polecat (defaults to its own bead)."
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
                "Refinery opens the bead's single canonical PR with."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.bead_update_progress/2
    },

    # ---- Phase 2: coordinator-only mutating tools ----
    %{
      name: "bead_create",
      tiers: @coordinator,
      description:
        "Create a bead in the workspace. `title` is required; optional `description`, " <>
          "`acceptance`, `priority`, `difficulty`, `issue_type`, `auto_close`, `assignee`, " <>
          "`tracker_type`, …. The bead is always created in the coordinator's own workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Bead title (required)."},
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
              "When true, this bead auto-closes once all its `parent_of` children are closed " <>
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
      handler: &Tools.bead_create/2
    },
    %{
      name: "bead_update",
      tiers: @coordinator,
      description:
        "Update a bead in the workspace (status / priority / title / …). To close a bead use " <>
          "`bead_close`; the `closed` status is rejected here.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Bead id (required)."},
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
            "description" => "Auto-close this bead when all its `parent_of` children are closed."
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
      handler: &Tools.bead_update/2
    },
    %{
      name: "bead_close",
      tiers: @coordinator,
      description:
        "Close a bead in the workspace. Optional `reason`; `close_upstream: true` also closes the " <>
          "linked external tracker issue.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Bead id (required)."},
          "reason" => %{"type" => "string"},
          "close_upstream" => %{
            "type" => "boolean",
            "description" => "Also close the linked tracker issue (default false)."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.bead_close/2
    },
    %{
      name: "bead_reopen",
      tiers: @coordinator,
      description:
        "Reopen a closed bead (clears closed_at, returns it to the ready queue, and best-effort " <>
          "reopens the linked tracker issue). The only supported path out of `closed` — `bead_update` " <>
          "rejects that transition.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Bead id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.bead_reopen/2
    },
    %{
      name: "dep_add",
      tiers: @coordinator,
      description:
        "Add a dependency edge between two beads in the workspace. `type` is one of blocks, " <>
          "depends_on, relates_to, discovered_from, parent_of. Use `parent_of` (from = parent, " <>
          "to = child) to attach a child to a parent bead — that is how grouping/epics work; the " <>
          "parent then rolls up child progress and can auto-close.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from_issue_id" => %{"type" => "string", "description" => "The dependent bead."},
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
        "Remove dependency edges between two beads in the workspace. Omit `type` to remove every " <>
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
      name: "polecat_sling",
      tiers: @coordinator,
      description:
        "Dispatch a polecat to work a bead in the workspace. Requires a `can_sling` coordinator " <>
          "token and is depth-limited (the sling-recursion guardrail). Pass `provider` to start a " <>
          "worker session (`claude` or `gemini`); omit it to park the bead in_progress.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{"type" => "string", "description" => "Bead to sling (required)."},
          "rig" => %{"type" => "string", "description" => "Rig to run in (optional)."},
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "provider" => %{
            "type" => "string",
            "enum" => ["claude", "gemini"],
            "description" =>
              "Worker provider to dispatch. Omit to park the bead in_progress (no worker)."
          },
          "with_claude" => %{
            "type" => "boolean",
            "description" =>
              "DEPRECATED alias for `provider: \"claude\"`. `true` → start a Claude worker."
          }
        },
        "required" => ["bead_id"],
        "additionalProperties" => false
      },
      handler: &Tools.polecat_sling/2
    },
    %{
      name: "polecat_resume",
      tiers: @coordinator,
      description:
        "Re-attach a fresh worker to a bead's preserved worktree (`arb resume`), continuing " <>
          "the stopped run rather than restarting. Requires a `can_sling` coordinator token and is " <>
          "depth-limited (the sling-recursion guardrail).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{"type" => "string", "description" => "Bead to resume (required)."},
          "rig" => %{
            "type" => "string",
            "description" => "Rig to run in (optional; inherited from the bead's last run)."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."}
        },
        "required" => ["bead_id"],
        "additionalProperties" => false
      },
      handler: &Tools.polecat_resume/2
    },
    %{
      name: "polecat_review",
      tiers: @coordinator,
      description:
        "Dispatch a review-only worker against the PR/MR linked to a bead (`arb review`): no worktree, " <>
          "no branch, no merge. Requires a `can_sling` coordinator token and is depth-limited. " <>
          "Claude-driven by default; pass `with_claude: false` to dispatch without spawning an agent.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{"type" => "string", "description" => "Bead to review (required)."},
          "rig" => %{
            "type" => "string",
            "description" => "Local checkout the reviewer runs in (needs `gh`/`git`)."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "with_claude" => %{
            "type" => "boolean",
            "description" => "Spawn the reviewer agent (default true)."
          }
        },
        "required" => ["bead_id"],
        "additionalProperties" => false
      },
      handler: &Tools.polecat_review/2
    },
    %{
      name: "polecat_stop",
      tiers: @coordinator,
      description:
        "Stop the polecat currently working a bead (`arb polecat stop`). Scoped to the coordinator's " <>
          "workspace; a bead with no live polecat is reported not-found. Teardown only — does not sling.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{
            "type" => "string",
            "description" => "Bead whose polecat to stop (required)."
          }
        },
        "required" => ["bead_id"],
        "additionalProperties" => false
      },
      handler: &Tools.polecat_stop/2
    },
    %{
      name: "message_send",
      tiers: @both,
      description:
        "Send a message to a bead's mailbox (the structured replacement for `arb message <bead> <text>`). " <>
          "A coordinator sends a direction from `coordinator`; a polecat raises a flag from its own bead " <>
          "to a sibling. The sender identity is set from the scope and pinned to its workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{"type" => "string", "description" => "Recipient bead id (required)."},
          "body" => %{"type" => "string", "description" => "Message body (required)."},
          "subject" => %{"type" => "string"}
        },
        "required" => ["bead_id", "body"],
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
      name: "polecat_list",
      tiers: @coordinator,
      description:
        "List active polecats in the workspace: bead_id, status, rig, started_at, activity, " <>
          "model (short display name e.g. \"Sonnet\"), and cost_usd (sum of all ledger entries for the bead).",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.polecat_list/2
    },
    %{
      name: "bead_list",
      tiers: @coordinator,
      description:
        "List beads in the workspace with optional filters. `status` (open | in_progress | closed), " <>
          "`priority` (integer 0–4), and `issue_type` (task | bug | feature | epic | chore | decision) " <>
          "are all optional. Returns matching beads in the coordinator's workspace.",
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
      handler: &Tools.bead_list/2
    },
    %{
      name: "tracker_claim",
      tiers: @coordinator,
      description:
        "Claim an external tracker issue into a bead (`arb claim <issue#>`). Verifies the issue is " <>
          "assigned to the workspace user (skip with `force: true`) and creates a linked bead. " <>
          "Idempotent — returns the existing bead if one already references the issue.",
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
        "Reconcile the workspace's beads against its external tracker (`arb sync`): bead assigned issues " <>
          "with no bead, close beads whose issue is gone. `dry: true` returns the plan without acting. " <>
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
        "Roll up the token/cost usage ledger for the workspace. `by` is required (day, bead, " <>
          "campaign, workspace, rig, model, step, provider); optional `since` (ISO-8601) and `limit`.",
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
