defmodule Arbiter.Tasks.Claim do
  @moduledoc """
  Bridges tracker issues ↔ tasks via the "claim then task" model.

  Tracker issues are the shared backlog; *assignment is the claim*. A task is
  created only for an issue assigned to the workspace's authenticated user — so
  the fleet never tasks work someone else owns.

  Generalised over the `Tracker` behaviour: works with any adapter that
  implements `current_user/0` (GitHub, Jira, Shortcut). Trackers that return
  `{:error, :not_supported}` from `current_user/0` (e.g. `None`) degrade
  cleanly: `claim/3` returns `{:error, :tracker_not_supported}` and `plan/1`
  returns `{:ok, []}`.

  Two operations:

    * `claim/3` — fetch one issue by ref and create a linked task (idempotent).
    * `plan/1` + `apply_plan/3` — reconcile assigned-to-viewer open issues
      against open tasks, in both directions.
  """

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Trackers

  require Ash.Query

  @typedoc "Outcome of a single claim attempt."
  @type claim_result ::
          {:ok, :created | :existing, Issue.t()}
          | {:error, atom() | String.t() | map()}

  @typedoc "A planned reconciliation action."
  @type action ::
          {:create, ref :: String.t(), summary :: map()}
          | {:close, issue_id :: String.t(), reason :: String.t()}

  @typedoc "Outcome of applying a single planned action."
  @type action_result ::
          {:created, Issue.t()}
          | {:closed, Issue.t()}
          | {:error, action(), term()}

  @doc """
  Claim a tracker issue: fetch it via the workspace adapter, refuse unless it
  is assigned to the workspace's authenticated user (overridable with
  `force: true`), and create a task linked by `tracker_ref`. Idempotent:
  returns the existing task if one already references the issue.

  For adapters that implement the optional `check_prior_claim/1` callback
  (currently GitHub), also checks for an existing ownership comment and refuses
  if another Arbiter installation has already claimed the issue.

  For adapters that implement the optional `signal_claim/3` callback (currently
  GitHub), posts an ownership comment and assigns the issue to the viewer after
  creating the task. These side-effects are non-fatal.

  Options:

    * `:force` — when `true`, skip both the assignment check and the prior
      claim check.

  Returns:

    * `{:ok, :created, %Issue{}}` — a new task was inserted.
    * `{:ok, :existing, %Issue{}}` — a task for this ref already existed.
    * `{:error, :tracker_not_supported}` — the workspace's tracker does not
      support the claim operation (e.g. `none`).
    * `{:error, {:not_assigned, identity}}` — the issue isn't assigned to the
      workspace's authenticated user.
    * `{:error, {:already_claimed, body}}` — another Arbiter installation has
      already claimed this issue (override with `force: true`).
    * `{:error, term}` — surfaced from the tracker adapter or Ash.
  """
  @spec claim(Workspace.t(), String.t(), keyword()) :: claim_result
  def claim(%Workspace{} = workspace, ref, opts \\ []) when is_binary(ref) do
    type = Trackers.workspace_type(workspace)
    adapter = Trackers.for_type(type)
    force? = Keyword.get(opts, :force, false)

    Trackers.with_workspace(type, workspace, fn ->
      do_claim(adapter, type, workspace, ref, force?)
    end)
  end

  @doc """
  Build a reconcile plan for the workspace. Two directions:

    * issue assigned to viewer + open + no open task → `{:create, ref, summary}`.
    * open task with a tracker ref whose issue is unassigned (or closed) →
      `{:close, task_id, reason}`.

  Returns `{:ok, plan}` or `{:error, reason}`. `plan` is an empty list when
  the workspace tracker doesn't support the claim operation.
  """
  @spec plan(Workspace.t()) :: {:ok, [action()]} | {:error, term()}
  def plan(%Workspace{} = workspace) do
    type = Trackers.workspace_type(workspace)
    adapter = Trackers.for_type(type)

    Trackers.with_workspace(type, workspace, fn ->
      case adapter.current_user() do
        {:ok, current_user_id} -> build_plan(workspace, adapter, type, current_user_id)
        {:error, :not_supported} -> {:ok, []}
        {:error, _} = err -> err
      end
    end)
  end

  @doc """
  Execute a previously-built `plan/1`. Each action is attempted independently;
  failures are reported per-action but do not halt the rest of the plan.

  Returns `{:ok, [action_result]}` — the per-action results in the same order
  as the input plan.
  """
  @spec apply_plan(Workspace.t(), [action()], keyword()) :: {:ok, [action_result]}
  def apply_plan(%Workspace{} = workspace, plan, _opts \\ []) when is_list(plan) do
    results = Enum.map(plan, &apply_action(workspace, &1))
    {:ok, results}
  end

  # ---- internals: claim ----------------------------------------------------

  defp do_claim(adapter, type, workspace, ref, force?) do
    with {:ok, current_user_id} <- get_current_user(adapter, workspace),
         {:ok, ref} <- normalize_ref(adapter, ref),
         {:ok, issue_map} <- adapter.fetch(ref),
         :ok <- check_assignment(adapter, issue_map, current_user_id, force?) do
      case find_existing(workspace, type, ref) do
        {:ok, task} ->
          {:ok, :existing, task}

        :none ->
          with :ok <- maybe_check_prior_claim(adapter, ref, force?) do
            case create_task(workspace, type, ref, issue_map, adapter) do
              {:ok, :created, task} = result ->
                maybe_signal_claim(adapter, ref, task, workspace, current_user_id)
                result

              error ->
                error
            end
          end
      end
    end
  end

  defp create_task(workspace, type, ref, issue_map, adapter) do
    attrs =
      %{
        title: adapter.extract_title(issue_map),
        description: adapter.extract_description(issue_map),
        tracker_type: type,
        tracker_ref: ref,
        workspace_id: workspace.id
      }
      |> maybe_put_extracted(:priority, adapter, :extract_priority, issue_map)
      |> maybe_put_extracted(:difficulty, adapter, :extract_difficulty, issue_map)

    case Ash.create(Issue, attrs) do
      {:ok, task} -> {:ok, :created, task}
      {:error, err} -> {:error, err}
    end
  end

  defp maybe_put_extracted(attrs, field, adapter, callback, issue_map) do
    if function_exported?(adapter, callback, 1) do
      case apply(adapter, callback, [issue_map]) do
        {:ok, value} -> Map.put(attrs, field, value)
        nil -> attrs
      end
    else
      attrs
    end
  end

  defp find_existing(workspace, type, ref) do
    query =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace.id and tracker_type == ^type and tracker_ref == ^ref
      )

    case Ash.read(query) do
      {:ok, [task | _]} -> {:ok, task}
      {:ok, []} -> :none
      {:error, _} = err -> err
    end
  end

  # bd-6xaaam: `force: true` may bypass the "not yet assigned to viewer" check
  # (e.g. claiming an unassigned issue), but it must NEVER silently reassign an
  # issue that is already owned by a different user. Doing so would overwrite a
  # colleague's assignment — exactly the incident that triggered this fix.
  defp check_assignment(adapter, issue_map, current_user_id, force) do
    assignees = adapter.assignees(issue_map)

    cond do
      current_user_id in assignees ->
        # Already assigned to the workspace user — always OK.
        :ok

      Enum.empty?(assignees) and force ->
        # Unassigned issue: force lets the caller claim without prior assignment.
        :ok

      not Enum.empty?(assignees) ->
        # Assigned to SOMEONE ELSE — refuse regardless of force to avoid
        # silently taking over a colleague's ticket.
        {:error, {:not_assigned, current_user_id}}

      true ->
        # Unassigned but no force.
        {:error, {:not_assigned, current_user_id}}
    end
  end

  defp maybe_check_prior_claim(_adapter, _ref, true), do: :ok

  defp maybe_check_prior_claim(adapter, ref, false) do
    if function_exported?(adapter, :check_prior_claim, 1) do
      adapter.check_prior_claim(ref)
    else
      :ok
    end
  end

  defp maybe_signal_claim(adapter, ref, task, workspace, current_user_id) do
    if function_exported?(adapter, :signal_claim, 3) do
      host = System.get_env("ARB_HOST") || local_hostname()

      context = %{
        task_id: task.id,
        workspace_name: workspace.name,
        workspace_prefix: workspace.prefix,
        current_user: current_user_id,
        host: host
      }

      adapter.signal_claim(ref, task.id, context)
    else
      :ok
    end
  end

  # ---- internals: plan -----------------------------------------------------

  defp build_plan(workspace, adapter, type, current_user_id) do
    with {:ok, summaries} <- adapter.list_open(assignee: current_user_id) do
      assigned_by_ref = Map.new(summaries, &{&1.ref, &1})

      open_tracker_tasks = read_open_tracker_tasks(workspace, type)
      task_by_ref = Map.new(open_tracker_tasks, &{&1.tracker_ref, &1})

      creates =
        for {ref, summary} <- assigned_by_ref, not Map.has_key?(task_by_ref, ref) do
          {:create, ref,
           %{
             ref: ref,
             title: summary.title,
             url: summary.url
           }}
        end

      closes =
        for {ref, task} <- task_by_ref, not Map.has_key?(assigned_by_ref, ref) do
          reason =
            case adapter.fetch(ref) do
              {:ok, issue} ->
                cond do
                  adapter.issue_status(issue) == :closed ->
                    "tracker issue #{ref} closed"

                  adapter.assignees(issue) == [] ->
                    "tracker issue #{ref} unassigned"

                  true ->
                    "tracker issue #{ref} reassigned to #{Enum.join(adapter.assignees(issue), ", ")}"
                end

              {:error, _} ->
                "tracker issue #{ref} no longer assigned"
            end

          {:close, task.id, reason}
        end

      {:ok, Enum.sort(creates ++ closes, &action_order/2)}
    end
  end

  defp action_order({:create, a, _}, {:create, b, _}), do: a <= b
  defp action_order({:close, a, _}, {:close, b, _}), do: a <= b
  defp action_order({:create, _, _}, {:close, _, _}), do: true
  defp action_order({:close, _, _}, {:create, _, _}), do: false

  defp read_open_tracker_tasks(workspace, type) do
    query =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace.id and tracker_type == ^type and status != :closed and
          not is_nil(tracker_ref)
      )

    case Ash.read(query) do
      {:ok, list} -> list
      _ -> []
    end
  end

  # ---- internals: apply ---------------------------------------------------

  defp apply_action(workspace, {:create, ref, _summary} = action) do
    case claim(workspace, ref) do
      {:ok, :created, task} -> {:created, task}
      {:ok, :existing, task} -> {:created, task}
      {:error, reason} -> {:error, action, reason}
    end
  end

  defp apply_action(_workspace, {:close, task_id, reason} = action) do
    with {:ok, task} <- Ash.get(Issue, task_id),
         {:ok, closed} <-
           Ash.update(task, %{reason: reason}, action: :close) do
      {:closed, closed}
    else
      {:error, reason} -> {:error, action, reason}
    end
  end

  # ---- internals: viewer caching ------------------------------------------

  # The current user identity is workspace-scoped and stable for the duration
  # of a request, so we look it up once per workspace and cache in the process
  # dict to avoid hitting the API multiple times during a single sync.
  defp get_current_user(adapter, workspace) do
    key = {__MODULE__, :current_user, workspace.id}

    case Process.get(key) do
      {:ok, _} = cached ->
        cached

      _ ->
        case adapter.current_user() do
          {:ok, id} = ok ->
            Process.put(key, ok)
            {:ok, id}

          {:error, :not_supported} ->
            {:error, :tracker_not_supported}

          {:error, _} = err ->
            err
        end
    end
  end

  # ---- internals: helpers --------------------------------------------------

  defp normalize_ref(adapter, ref) when is_binary(ref) do
    case adapter.parse_ref(ref) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_ref, ref}}
    end
  end

  defp local_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "unknown"
    end
  end
end
