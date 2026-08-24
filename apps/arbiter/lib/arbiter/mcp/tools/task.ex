defmodule Arbiter.MCP.Tools.Task do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for reading and mutating tasks: `task_show` /
  `task_ready` / `task_update_progress` / `task_create` / `task_update` /
  `task_close` / `task_reopen` / `task_sync_upstream_close` / `dep_add` /
  `dep_remove`. Split out of `Arbiter.MCP.Tools` (see its moduledoc) — called
  back into for the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue

  require Ash.Query

  @progress_fields ~w(notes qa_notes deployment_notes pr_body)

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

      {:ok, result}
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
         {:ok, attrs} <- progress_attrs(args) do
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
  Create a task in a workspace. Coordinator only. The target workspace is
  resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default — and `workspace_id` is then forced
  onto the task. Backs onto `Ash.create(Issue, …)` (the same path `arb create` /
  the REST `POST /api/issues` take), so a workspace with a tracker configured
  still mirrors the new task upstream.
  """
  @spec task_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, title} <- Tools.require_string(args, "title"),
         {:ok, attrs} <- Tools.collect_attrs(args, task_create_spec()) do
      attrs = attrs |> Map.put("title", title) |> Map.put("workspace_id", ws_id)

      case Ash.create(Issue, attrs) do
        {:ok, issue} -> {:ok, Tools.serialize_task_summary(issue)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

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
         {:ok, attrs} <- Tools.collect_attrs(args, task_update_spec()),
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
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      case Ash.update(issue, %{}, action: :promote_to_ready) do
        {:ok, promoted} -> {:ok, Tools.serialize_task_summary(promoted)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

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

  # ---- dep_add ------------------------------------------------------------

  @doc """
  Add a dependency edge between two tasks in the scope's workspace. Coordinator
  only. Both endpoints must resolve inside the workspace (a cross-workspace id is
  reported not-found). Backs onto `Ash.create(Dependency, …)`.
  """
  @spec dep_add(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_add(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.require_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to) do
      attrs =
        %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}
        |> Tools.maybe_put("notes", Tools.fetch_string(args, "notes"))
        |> Tools.maybe_put("created_by", Tools.fetch_string(args, "created_by"))

      case Ash.create(Dependency, attrs) do
        {:ok, dep} -> {:ok, Tools.serialize_dependency(dep)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- dep_remove ---------------------------------------------------------

  @doc """
  Remove dependency edges between two tasks in the scope's workspace. Coordinator
  only. With no `type` every edge between the pair is removed; with a `type`
  only that edge. Idempotent — removing an absent edge reports `removed: 0`.
  """
  @spec dep_remove(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_remove(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.optional_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to) do
      edges = find_dep_edges(from, to, type)
      _ = Enum.each(edges, &Ash.destroy!/1)
      {:ok, %{from_issue_id: from, to_issue_id: to, removed: length(edges)}}
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

  # Keep only the three allowed progress fields; require at least one.
  defp progress_attrs(args) do
    attrs =
      for field <- @progress_fields, (val = Tools.fetch_string(args, field)) != nil, into: %{} do
        {String.to_existing_atom(field), val}
      end

    if map_size(attrs) == 0 do
      {:error, {:invalid, "provide at least one of: #{Enum.join(@progress_fields, ", ")}"}}
    else
      {:ok, attrs}
    end
  end

  defp find_dep_edges(from, to, nil) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to)
    |> Ash.read!()
  end

  defp find_dep_edges(from, to, type) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to and type == ^type)
    |> Ash.read!()
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
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"target_branch", :string}
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
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string}
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
      status: Tools.to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: Tools.to_str(i.issue_type)
    }
    |> Tools.put_progress(i)
  end
end
