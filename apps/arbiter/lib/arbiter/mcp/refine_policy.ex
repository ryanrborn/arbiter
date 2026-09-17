defmodule Arbiter.MCP.RefinePolicy do
  @moduledoc """
  The tool-level allow/deny table for the `:refine` scope tier (bd-3uy2hn).

  ## Why a table and not a `:tiers` entry

  Every other tier declares its tools inline, in each `Arbiter.MCP.Catalog` entry's
  `:tiers` list. The refine tier does not, for one reason: **a tool added to the
  catalog with no `:refine` in its `:tiers` is silently denied, and a tool added
  with one is silently allowed — either way, nobody had to decide.** For a tier
  whose whole purpose is to hand a browser session a narrow slice of the
  coordinator's authority, "nobody decided" is the failure mode that matters.

  So the decision lives here, once, for every tool, and
  `Arbiter.MCP.RefinePolicyTest` fails the build when a catalog tool has no entry.
  Adding an MCP tool now forces an explicit answer to "may a refine session call
  this?".

  ## The permission set

  **Reads are broad.** Refining an issue means reading its neighbours — the epic
  above it, the sibling that already solved half the problem, the repo it belongs
  to, the skills a worker would bring. The task-, workspace- and graph-shaped
  reads resolve their target through `Arbiter.MCP.Tools.authorized_workspace/2` /
  `Arbiter.MCP.Tools.resolve_workspace_id/2`, which pin a workspace-bound scope to
  its own workspace, so breadth there costs nothing across workspaces.

  `repo_list` / `repo_show` are the deliberate exception: repos are an
  installation-level registry, not a per-workspace one, and those two handlers
  ignore the scope and return the installation-wide list. That is intended — a
  refine session needs to name the repo a task belongs to — and it is a read of
  configuration, not of anyone's work.

  **Writes are narrow, and doubly gated.** A tool being allowed here only means a
  refine session may *call* it; the handler then requires the target to be the
  bound issue or a `parent_of` descendant of it
  (`Arbiter.MCP.Tools.authorize_subtree/2`). Allowing `task_update` does not allow
  updating any task — it allows updating a task in the subtree.

  **Nothing that starts, stops, or closes work.** No dispatch (`can_dispatch` is
  hard-wired false on the tier), no `task_close`/`task_reopen`/`task_verify`, no
  scheduler or circuit-breaker controls, no graph mutations, no installation or
  workspace config writes, no skill writes, no outbound mail. A refine session
  shapes a backlog item and promotes it; the board decides what happens next.
  """

  alias Arbiter.MCP.Catalog

  @type decision :: :allow | {:deny, String.t()} | :undecided

  # --- allowed: the read surface -------------------------------------------
  #
  # Everything here is a pure read, scoped to the token's bound workspace.
  @allow_reads ~w(
    task_show
    task_list
    task_ready
    workspace_show
    workspace_config_get
    workspace_config_overview
    graph_status
    repo_list
    repo_show
    skill_list
    skill_get
  )

  # --- allowed: the subtree write surface ----------------------------------
  #
  # Each of these is additionally gated by `Tools.authorize_subtree/2` inside its
  # handler — being callable is not being unrestricted.
  @allow_writes ~w(
    task_update
    task_update_progress
    task_create
    task_promote
    dep_add
    dep_remove
  )

  # --- denied, with the reason the caller sees -----------------------------
  @deny_reason_dispatch "a refine session shapes work, it never starts it (can_dispatch is always false)"
  @deny_reason_lifecycle "a refine session may promote from Backlog but never close, reopen or verify a task"
  @deny_reason_worker_ops "worker operations are outside a refine session's authority"
  @deny_reason_config "configuration is installation state, not issue state"
  @deny_reason_graph "graph mutation schedules work; a refine session only reads graph state"
  @deny_reason_scheduler "board and breaker controls are coordinator authority"
  @deny_reason_mail "a refine session cannot send mail or flag other sessions"
  @deny_reason_review "review gating is coordinator authority"
  @deny_reason_ops "operational triage is outside a refine session's authority"
  @deny_reason_tracker "upstream tracker sync is coordinator authority"
  @deny_reason_scope "a refine session is bound to one workspace and one issue"

  @deny %{
    # lifecycle / status
    "task_close" => @deny_reason_lifecycle,
    "task_reopen" => @deny_reason_lifecycle,
    "task_verify" => @deny_reason_lifecycle,
    "task_sync_upstream_close" => @deny_reason_lifecycle,

    # dispatch
    "worker_dispatch" => @deny_reason_dispatch,
    "worker_resume" => @deny_reason_dispatch,
    "worker_review" => @deny_reason_dispatch,

    # worker observation / control
    "worker_stop" => @deny_reason_worker_ops,
    "worker_list" => @deny_reason_worker_ops,
    "worker_show" => @deny_reason_worker_ops,
    "worker_runs" => @deny_reason_worker_ops,
    "worker_log" => @deny_reason_worker_ops,
    "worker_prompt" => @deny_reason_worker_ops,
    "run_log_list" => @deny_reason_worker_ops,
    "transcript_capture_stats" => @deny_reason_worker_ops,

    # review
    "external_review_list" => @deny_reason_review,
    "external_review_show" => @deny_reason_review,
    "external_review_transcript" => @deny_reason_review,
    "review_gate_rounds_list" => @deny_reason_review,
    "review_greenlight" => @deny_reason_review,

    # mail
    "inbox_check" => @deny_reason_mail,
    "coordinator_inbox" => @deny_reason_mail,
    "coordinator_inbox_clear" => @deny_reason_mail,
    "message_send" => @deny_reason_mail,
    "notify_list" => @deny_reason_mail,

    # config
    "workspace_config_set" => @deny_reason_config,
    "workspace_config_unset" => @deny_reason_config,
    "installation_config_get" => @deny_reason_config,
    "installation_config_set" => @deny_reason_config,
    "skill_create" => @deny_reason_config,
    "skill_update" => @deny_reason_config,
    "skill_delete" => @deny_reason_config,

    # graph mutation
    "graph_create" => @deny_reason_graph,
    "graph_add_directive" => @deny_reason_graph,
    "graph_remove_directive" => @deny_reason_graph,
    "graph_add_edge" => @deny_reason_graph,
    "graph_start" => @deny_reason_graph,
    "graph_pause" => @deny_reason_graph,
    "graph_resume" => @deny_reason_graph,

    # board / breakers / queue
    "scheduler_pause" => @deny_reason_scheduler,
    "scheduler_resume" => @deny_reason_scheduler,
    "scheduler_status" => @deny_reason_scheduler,
    "breaker_list" => @deny_reason_scheduler,
    "breaker_reset" => @deny_reason_scheduler,
    "queue_resume" => @deny_reason_ops,
    "queue_retry_auto_resolve" => @deny_reason_ops,
    "queue_restart_watchdog" => @deny_reason_ops,
    "ci_rerun" => @deny_reason_ops,
    "ci_mark_external" => @deny_reason_ops,
    "loop_pending_list" => @deny_reason_ops,
    "loop_pending_diff" => @deny_reason_ops,
    "loop_pending_apply" => @deny_reason_ops,
    "loop_pending_reject" => @deny_reason_ops,

    # tracker
    "tracker_claim" => @deny_reason_tracker,
    "tracker_sync" => @deny_reason_tracker,

    # out of scope for a single-workspace, single-issue token
    "workspace_list" => @deny_reason_scope,
    "quota_get" => @deny_reason_scope,
    "usage_summarize" => @deny_reason_scope
  }

  @allowed @allow_reads ++ @allow_writes
  @decisions Map.new(@allowed, &{&1, :allow})
             |> Map.merge(Map.new(@deny, fn {name, reason} -> {name, {:deny, reason}} end))

  # A name cannot be both allowed and denied — the table would then depend on
  # merge order rather than on a decision. Caught at compile time.
  @overlap MapSet.intersection(MapSet.new(@allowed), MapSet.new(Map.keys(@deny)))
  if MapSet.size(@overlap) > 0 do
    raise "Arbiter.MCP.RefinePolicy: tools both allowed and denied: " <>
            inspect(MapSet.to_list(@overlap))
  end

  @doc """
  The refine-tier decision for a tool: `:allow`, `{:deny, reason}`, or
  `:undecided` for a tool this table has never heard of.

  `:undecided` is never treated as permission — `allow?/1` is false for it, and
  the conformance test fails the build so it cannot survive a commit.
  """
  @spec decision(String.t()) :: decision()
  def decision(name) when is_binary(name), do: Map.get(@decisions, name, :undecided)

  @doc "Whether a refine-tier scope may call `name` at all (tool-level gate only)."
  @spec allow?(String.t()) :: boolean()
  def allow?(name) when is_binary(name), do: decision(name) == :allow

  @doc "Every tool name this table decides, allowed or denied."
  @spec decided() :: [String.t()]
  def decided, do: Map.keys(@decisions)

  @doc "The tool names a refine-tier scope may call."
  @spec allowed() :: [String.t()]
  def allowed, do: @allowed

  @doc """
  The authorization message for a tool a refine session may not call — the exact
  string the transport returns as the JSON-RPC error. Names the tool and why, so
  a refine agent can adapt rather than retry.
  """
  @spec denial_message(String.t()) :: String.t()
  def denial_message(name) when is_binary(name) do
    case decision(name) do
      {:deny, reason} ->
        "Tool #{name} is not permitted for a refine scope: #{reason}"

      _ ->
        "Tool #{name} is not permitted for a refine scope"
    end
  end

  @doc """
  The tools in the catalog with no decision here. `[]` in a healthy build; the
  conformance test asserts exactly that.
  """
  @spec undecided_tools() :: [String.t()]
  def undecided_tools do
    Catalog.all()
    |> Enum.map(& &1.name)
    |> Enum.filter(&(decision(&1) == :undecided))
  end
end
