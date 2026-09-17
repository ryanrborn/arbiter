defmodule Arbiter.MCP.Tools.Task do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for reading and mutating tasks: `task_show` /
  `task_ready` / `task_update_progress` / `task_create` / `task_update` /
  `task_close` / `task_reopen` / `task_verify` / `task_sync_upstream_close` / `dep_add` /
  `dep_remove`. Split out of `Arbiter.MCP.Tools` (see its moduledoc) — called
  back into for the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Usage.Estimate

  require Ash.Query

  @progress_fields ~w(notes qa_notes deployment_notes pr_body)

  # bd-9so315: the one non-text field a worker may set on its own task. It is a
  # self-declaration about its own diff ("this only runs inside the long-lived
  # server"), which the worker is the best-placed party to make and which
  # nothing else in the pipeline can infer — and unlike status/priority it
  # cannot reroute or reprioritize work: its only effect is that the task waits
  # for a human observation before closing.
  @progress_flags ~w(verify_after_deploy)

  # bd-3uy2hn: the fields a `:refine` token may write on a task in its subtree.
  # Deliberately excludes `status` (lifecycle belongs to the board, and closing
  # has its own tool), everything tracker- or assignment-shaped, and `pr_ref` /
  # `target_branch` / `pr_body` — a refine session shapes *what the work is*, not
  # who does it, where it lands, or whether it is done.
  @refine_writable_fields ~w(title description acceptance notes qa_notes deployment_notes
                             issue_type difficulty priority repo verify_after_deploy)

  # bd-3uy2hn / coordinator doctrine: Autopilot can claim a task within seconds
  # of it becoming Ready, so any child or edge that must exist before work starts
  # has to exist *before* the promote, not after. Returned on every refine-tier
  # promotion so the rule travels with the action, not just the docs.
  @edges_before_promote "Edges before promote: Autopilot can claim this task within seconds " <>
                          "of it going Ready, so every parent_of child and depends_on edge it " <>
                          "needs must already exist. Promote last."

  # ---- task_show ----------------------------------------------------------

  @doc "Read a single task. Worker: its own task only. Coordinator: any in its workspace."
  @spec task_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_show(%Scope{} = scope, args) do
    full = Map.get(args, "full") == true

    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      loaded = load_progress(issue)
      result = if(full, do: Tools.serialize_task(loaded), else: serialize_task_slim(loaded))
      # Strip pr_body from coordinator full-view (bandwidth; coordinators don't
      # need the body they didn't write). Worker full-view retains it so the
      # worker can verify its own authored body (bd-53xrmi).
      result =
        if full and scope.tier == :coordinator,
          do: Map.delete(result, :pr_body),
          else: result

      # bd-3j4ch4: what tasks like this one have actually cost, as a
      # percentile range. `nil` when the ledger is too thin — never a made-up
      # number, and never absent, so "no estimate yet" can't read as "$0".
      result = Map.put(result, :estimate, Estimate.payload(loaded))

      # bd-18vl9q: the epic cost rollup (design bd-9jj5lf §4). `nil` for a
      # non-epic issue — the field always rides along so callers don't have to
      # branch on `issue_type` to know whether to look for it.
      {:ok, Map.put(result, :epic_rollup, Estimate.epic_cost_rollup(loaded))}
    end
  end

  # ---- task_ready ---------------------------------------------------------

  @doc """
  List ready (unblocked, open) tasks in a workspace. Coordinator only. The
  workspace is resolved from the optional `workspace` arg, else the scope's bound
  workspace, else the installation default.
  """
  @spec task_ready(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_ready(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      tasks =
        [workspace_id: ws_id]
        |> Issue.ready()
        |> Enum.map(&Tools.serialize_task_summary/1)

      {:ok, %{tasks: tasks, count: length(tasks)}}
    end
  end

  # ---- task_update_progress ----------------------------------------------

  @doc """
  The worker's one write: record `notes` / `qa_notes` / `deployment_notes` /
  `pr_body` on its own task (the structured replacement for `arb issue update
  <id> --qa-notes …`). It cannot flip status, reprioritize, or touch another
  task. Coordinator: the same narrow write against any task in its workspace.
  """
  @spec task_update_progress(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update_progress(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, attrs} <- progress_attrs(args),
         {:ok, attrs} <- refine_field_gate(scope, attrs) do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, Tools.serialize_task_summary(updated)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ======================================================================
  # Phase 2 — coordinator-only mutating tools (docs/mcp-server-design.md §8)
  # ======================================================================

  # ---- task_create --------------------------------------------------------

  @doc """
  Create a task in a workspace. The target workspace is resolved from the optional
  `workspace` arg (name or id), else the scope's bound workspace, else the
  installation default — and `workspace_id` is then forced onto the task. Backs
  onto `Ash.create(Issue, …)` (the same path `arb create` / the REST
  `POST /api/issues` take), so a workspace with a tracker configured still mirrors
  the new task upstream.

  An optional `parent_id` attaches the new task as a `parent_of` child of an
  existing task in the same workspace, in one call.

  For a `:refine` scope (bd-3uy2hn) the parent is not optional: it defaults to the
  bound issue and must be the bound issue or one of its descendants, so a refine
  token cannot file a task outside its subtree. The parent is authorized *before*
  the task is created — a refused create leaves nothing behind. The same
  `refine_field_gate/2` that narrows `task_update` also runs here, so a refine
  session cannot set on create (`assignee`, `tracker_ref`, `target_branch`, …)
  what it would be refused on update.
  """
  @spec task_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, title} <- Tools.require_string(args, "title"),
         {:ok, parent_id} <- create_parent(scope, args, ws_id),
         {:ok, attrs} <- Tools.collect_attrs(args, task_create_spec()),
         # Gate *before* title/workspace_id are forced on: those two are set by
         # the tool, not by the caller, and a refine session is allowed both.
         {:ok, attrs} <- refine_field_gate(scope, attrs) do
      attrs = attrs |> Map.put("title", title) |> Map.put("workspace_id", ws_id)

      case Ash.create(Issue, attrs) do
        {:ok, issue} ->
          issue
          |> Tools.serialize_task_summary()
          |> with_ac_warning(issue)
          |> attach_parent(scope, issue, parent_id)

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # Resolve and authorize the `parent_of` parent for a create. `{:ok, nil}` means
  # "file it unparented", which only a non-refine scope can ask for.
  defp create_parent(%Scope{} = scope, args, ws_id) do
    named = Tools.fetch_string(args, "parent_id")
    requested = if scope.tier == :refine, do: named || scope.issue_id, else: named

    if is_nil(requested) do
      {:ok, nil}
    else
      with {:ok, parent} <- Tools.fetch_task_in_workspace(ws_id, requested),
           :ok <- Tools.authorize_subtree(scope, parent.id) do
        {:ok, parent.id}
      end
    end
  end

  @doc """
  Attach `issue` under `parent_id` with a `parent_of` edge.

  The edge is a second write, after `Ash.create(Issue, …)` and outside its
  transaction, so it can fail on its own — a parent deleted between the
  authorization and this call, or a resource-level rejection. When it does, the
  task is **kept**, and the error says so. That is deliberate, not an oversight:

    * An issue cannot be un-created. `Ash.destroy` on a task whose paper-trail
      version row already exists fails the version table's foreign key, so there
      is no compensating delete to run.
    * Rolling the pair back in one `Ash.transaction/2` is not available either:
      `Dependencies.add/4` opens its own, and under the test sandbox (and any
      caller already inside a transaction) `Ash.rollback/2` would abort the
      enclosing transaction rather than just this create.

  So the contract is: *the task exists, the edge does not.* For a coordinator
  that is a one-call fix (`dep_add`). For a refine session it is not — the
  unparented task sits outside the bound subtree, and a `parent_of` add needs
  both endpoints inside it (`Tools.authorize_subtree_edge/4`) — so the message
  names the id and says who can re-attach it. Either way nothing is silently
  half-done.

  Public (rather than private) so that contract is directly testable; the
  failure is otherwise only reachable by a race.
  """
  @spec attach_parent(map(), Scope.t(), Issue.t(), String.t() | nil) ::
          {:ok, map()} | {:error, {:invalid, String.t()}}
  def attach_parent(result, scope, issue, parent_id)

  def attach_parent(result, _scope, _issue, nil), do: {:ok, result}

  def attach_parent(result, %Scope{} = scope, %Issue{} = issue, parent_id) do
    case Dependencies.add(parent_id, issue.id, :parent_of,
           created_by: Arbiter.PaperTrail.actor_label(scope)
         ) do
      {:ok, _dep} ->
        {:ok, Map.put(result, :parent_id, parent_id)}

      {:error, reason} ->
        {:error, {:invalid, orphan_message(scope, issue, parent_id, reason)}}
    end
  end

  defp orphan_message(%Scope{tier: tier}, %Issue{} = issue, parent_id, reason) do
    recovery =
      if tier == :refine do
        " — it is filed in the workspace Backlog with no parent, which puts it " <>
          "outside this session's subtree: ask a coordinator to attach it with dep_add, or " <>
          "file it again once #{parent_id} is reachable"
      else
        " — the task is filed with no parent; attach it with dep_add rather than filing it again"
      end

    "task #{issue.id} was created, but the parent_of edge from #{parent_id} failed: " <>
      inspect(reason) <> recovery
  end

  # bd-7mbrlg: non-blocking heads-up at filing time — the task is created
  # either way, but `task_promote` will later refuse it without `acceptance`
  # or an explicit `acceptance_waived` reason.
  defp with_ac_warning(result, %Issue{} = issue) do
    if Issue.gated_type?(issue.issue_type) and blank?(issue.acceptance) do
      Map.put(result, :warnings, [
        "No acceptance criteria set. #{issue.issue_type} tasks need `acceptance` (or an " <>
          "explicit `acceptance_waived` reason) before they can be promoted to Ready."
      ])
    else
      result
    end
  end

  defp blank?(nil), do: true
  defp blank?(str), do: String.trim(str) == ""

  # Narrow a write to the fields a `:refine` token may set (bd-3uy2hn). Rejecting
  # a disallowed field is deliberate rather than silently dropping it: a refine
  # agent that asked to close a task must be told it cannot, not told "updated"
  # and left believing it did.
  #
  # Works on both attr shapes in this module — string keys from `collect_attrs/2`
  # and atom keys from `progress_attrs/1`.
  defp refine_field_gate(%Scope{tier: :refine}, attrs) do
    case Enum.reject(Map.keys(attrs), &(to_string(&1) in @refine_writable_fields)) do
      [] ->
        {:ok, attrs}

      refused ->
        {:error,
         {:unauthorized,
          "a refine session may not write " <>
            Enum.map_join(Enum.sort(refused), ", ", &to_string/1) <>
            " — it may set only: " <> Enum.join(@refine_writable_fields, ", ")}}
    end
  end

  defp refine_field_gate(%Scope{}, attrs), do: {:ok, attrs}

  # ---- task_update --------------------------------------------------------

  @doc """
  Update a task in the scope's workspace (status / priority / title / …).
  Coordinator only. The `:closed` status is rejected here — closing goes through
  `task_close`, which runs the close FSM + teardown. Backs onto the task's
  `:update` action.
  """
  @spec task_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, attrs} <- Tools.collect_attrs(args, task_update_spec()),
         {:ok, attrs} <- refine_field_gate(scope, attrs),
         :ok <- Tools.require_some(attrs, "provide at least one field to update") do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, Tools.serialize_task_summary(updated)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_close ---------------------------------------------------------

  @doc """
  Close a task in the scope's workspace via the `:close` action (sets status,
  runs the worker/worktree teardown, and syncs the close upstream by default
  when the task carries a `tracker_ref`). Pass `close_upstream: false` to leave
  the linked tracker issue open. Coordinator only.
  """
  @spec task_close(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_close(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         {:ok, close_upstream} <- Tools.fetch_bool(args, "close_upstream", true) do
      attrs =
        %{close_upstream: close_upstream}
        |> Tools.maybe_put(:reason, Tools.fetch_string(args, "reason"))

      case Ash.update(issue, attrs, action: :close) do
        {:ok, closed} -> {:ok, Tools.serialize_task_summary(closed)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_reopen --------------------------------------------------------

  @doc """
  Reopen a closed task in the scope's workspace via the `:reopen` action (clears
  `closed_at`, returns it to `:open` and the ready queue, and best-effort
  reopens the linked tracker issue). Coordinator only. Reopening is the only
  supported path out of `:closed` — the `:update` FSM rejects that transition —
  so a non-closed task is reported as an operational error.
  """
  @spec task_reopen(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_reopen(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      case Ash.update(issue, %{}, action: :reopen) do
        {:ok, reopened} -> {:ok, Tools.serialize_task_summary(reopened)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_promote --------------------------------------------------------

  @doc """
  Promote a task from Backlog to Ready (set `refined: true`) via the
  `:promote_to_ready` action. Coordinator only. Idempotent by design —
  promoting an already-refined task is a no-op success, not an error.
  """
  @spec task_promote(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_promote(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      promote_args =
        case Map.get(args, "acceptance_waived") do
          reason when is_binary(reason) -> %{acceptance_waived: reason}
          _ -> %{}
        end

      case Ash.update(issue, promote_args, action: :promote_to_ready) do
        {:ok, promoted} ->
          {:ok, with_promotion_note(Tools.serialize_task_summary(promoted), scope)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # The edges-before-promote rule, on the response of every refine-tier
  # promotion. Coordinators already own the scheduling doctrine; a refine session
  # is a fresh agent in a narrow scope, and the one ordering mistake it can make
  # that Arbiter cannot undo is promoting before wiring.
  defp with_promotion_note(result, %Scope{tier: :refine}),
    do: Map.put(result, :promotion_note, @edges_before_promote)

  defp with_promotion_note(result, %Scope{}), do: result

  # ---- task_sync_upstream_close --------------------------------------------

  @doc """
  Push a close to the linked tracker for a task that's already `:closed`
  locally but never synced upstream. Coordinator only. Backs onto the
  `:sync_upstream_close` action, which requires the task to already be
  `:closed` — a non-closed task is reported as an operational error — and
  makes no local status/closed_at change or close-time side effect (no
  StopWorker/CleanupWorktree/parent rollup).
  """
  @spec task_sync_upstream_close(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def task_sync_upstream_close(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      case Ash.update(issue, %{}, action: :sync_upstream_close) do
        {:ok, synced} -> {:ok, Tools.serialize_task_summary(synced)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_verify ---------------------------------------------------------

  @doc """
  Record the restart-and-observe result for a task parked at
  `:awaiting_verification` (bd-9so315). Coordinator only.

  Exactly one of `observed` / `failed` must be given, and its value is the
  evidence — what was actually seen on the running server. `observed` closes
  the task; `failed` reopens it for another attempt. Either way the evidence is
  persisted on the task, so the claim is auditable rather than remembered.
  """
  @spec task_verify(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_verify(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         {:ok, outcome, evidence} <- verify_verdict(args) do
      case Verification.record_outcome(issue, outcome, evidence) do
        {:ok, updated} -> {:ok, Tools.serialize_task_summary(updated)}
        {:error, reason} -> {:error, {:invalid, verify_error_message(reason)}}
      end
    end
  end

  defp verify_verdict(args) do
    observed = Tools.fetch_string(args, "observed")
    failed = Tools.fetch_string(args, "failed")

    case {observed, failed} do
      {nil, nil} ->
        {:error, {:invalid, "provide exactly one of: observed (evidence) or failed (evidence)"}}

      {obs, fail} when is_binary(obs) and is_binary(fail) ->
        {:error, {:invalid, "provide only one of: observed or failed, not both"}}

      {obs, nil} ->
        {:ok, :observed, obs}

      {nil, fail} ->
        {:ok, :failed, fail}
    end
  end

  defp verify_error_message(:not_awaiting_verification),
    do:
      "task is not awaiting verification — only a task parked at " <>
        "awaiting_verification can record a verify result"

  defp verify_error_message(:evidence_required),
    do: "evidence text is required: say what you observed on the running server"

  defp verify_error_message({:invalid, %{} = err}), do: Tools.ash_error_message(err)
  defp verify_error_message({:invalid, msg}) when is_binary(msg), do: msg
  defp verify_error_message(other), do: inspect(other)

  # ---- dep_add ------------------------------------------------------------

  @doc """
  Add a dependency edge between two tasks in the scope's workspace. Coordinator
  only. Both endpoints must resolve inside the workspace (a cross-workspace id is
  reported not-found, which is why the scope checks stay here and are not left
  to the facade's `:cross_workspace` error).

  The write itself goes through `Arbiter.Tasks.Dependencies.add/4` (bd-apj0gq),
  so it also gets the cycle guard and the `parent_of` auto-close re-evaluation.
  """
  @spec dep_add(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_add(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.require_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to),
         :ok <- Tools.authorize_subtree_edge(scope, from, to, type) do
      opts =
        []
        |> Tools.maybe_put_kw(:notes, Tools.fetch_string(args, "notes"))
        |> Tools.maybe_put_kw(:created_by, Tools.fetch_string(args, "created_by"))

      case Dependencies.add(from, to, type, opts) do
        {:ok, dep} -> {:ok, Tools.serialize_dependency(dep)}
        {:error, reason} -> Tools.dependency_error(reason)
      end
    end
  end

  # ---- dep_remove ---------------------------------------------------------

  @doc """
  Remove dependency edges between two tasks in the scope's workspace. Coordinator
  only. With no `type` every edge between the pair is removed; with a `type`
  only that edge. Idempotent — removing an absent edge reports `removed: 0`.

  Routed through `Arbiter.Tasks.Dependencies.remove/3` (bd-apj0gq), so detaching
  an epic's last open child now re-evaluates the parent's `auto_close`.
  """
  @spec dep_remove(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_remove(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.optional_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to),
         :ok <- Tools.authorize_subtree_edge(scope, from, to, type) do
      case Dependencies.remove(from, to, type) do
        {:ok, removed} -> {:ok, %{from_issue_id: from, to_issue_id: to, removed: removed}}
        {:error, reason} -> Tools.dependency_error(reason)
      end
    end
  end

  # Load the child-progress rollup calcs for a task so the serializer can emit
  # `child_total` / `child_closed`. Best-effort: on any load error the task is
  # returned unchanged (the serializer then omits the progress fields).
  defp load_progress(%Issue{} = issue) do
    Ash.load!(issue, [:child_total, :child_closed])
  rescue
    _ -> issue
  end

  # Keep only the allowed progress fields; require at least one.
  defp progress_attrs(args) do
    text =
      for field <- @progress_fields, (val = Tools.fetch_string(args, field)) != nil, into: %{} do
        {String.to_existing_atom(field), val}
      end

    flags =
      for field <- @progress_flags, is_boolean(val = Map.get(args, field)), into: %{} do
        {String.to_existing_atom(field), val}
      end

    attrs = Map.merge(text, flags)

    if map_size(attrs) == 0 do
      {:error,
       {:invalid,
        "provide at least one of: #{Enum.join(@progress_fields ++ @progress_flags, ", ")}"}}
    else
      {:ok, attrs}
    end
  end

  defp task_create_spec do
    [
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"verify_after_deploy", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"target_branch", :string},
      {"repo", :string}
    ]
  end

  defp task_update_spec do
    [
      {"title", :string},
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"status", {:enum, Issue.statuses()}},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"verify_after_deploy", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string},
      {"repo", :string}
    ]
  end

  # Slim serializer for worker task_show (full: false). Omits review/human
  # fields that bloat worker context without aiding task execution.
  defp serialize_task_slim(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      description: i.description,
      acceptance: i.acceptance,
      acceptance_waived: i.acceptance_waived,
      status: Tools.to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: Tools.to_str(i.issue_type)
    }
    |> Tools.put_progress(i)
  end
end
