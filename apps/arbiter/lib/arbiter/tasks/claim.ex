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
          | {:drift, issue_id :: String.t(), reason :: String.t()}

  @typedoc "Outcome of applying a single planned action."
  @type action_result ::
          {:created, Issue.t()}
          | {:closed, Issue.t()}
          | {:drifted, Issue.t()}
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
  Build a reconcile plan for the workspace. Three kinds of action:

    * issue assigned to viewer + open + no open task → `{:create, ref, summary}`.
    * open task whose tracker issue is closed upstream, or is now assigned to
      somebody other than the viewer → `{:close, task_id, reason}`. An issue
      that is merely *unassigned*, or that can't be fetched, yields no action
      (bd-83ojwi): unassigned is a resting state, not abandonment.
    * task closed locally whose linked tracker issue is still open (the
      bd-2wilou drift case — a close that never propagated upstream) →
      `{:drift, task_id, reason}`. This is report-only: `apply_plan/3` never
      writes anything for a `:drift` action, since fixing it means re-closing
      upstream (`task_sync_upstream_close`), not touching the local task.
      Only closes that were *meant* to propagate are eligible: a close carries
      a recorded `close_upstream_expected` (bd-bsco7f), and for rows predating
      that, `pr_ref`'s presence stands in (bd-83ojwi). `:task`-type and
      `review_only` tasks are exempt outright — research/investigation work and
      borrowed tickets are *expected* to close locally with the ticket still
      open upstream.

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
        task_by_ref
        |> Enum.reject(fn {ref, _task} -> Map.has_key?(assigned_by_ref, ref) end)
        |> Enum.flat_map(fn {ref, task} ->
          case close_reason(adapter, ref, current_user_id) do
            nil -> []
            reason -> [{:close, task.id, reason}]
          end
        end)

      drifts = build_drift(adapter, workspace, type)

      {:ok, Enum.sort(creates ++ closes ++ drifts, &action_order/2)}
    end
  end

  # bd-83ojwi: absence from `list_open(assignee: viewer)` is NOT on its own a
  # signal to close. That call only returns issues assigned to the viewer, so
  # an open-but-*unassigned* issue is absent from it too — and on these boards
  # unassigned is the normal resting state for backlog work, not abandonment
  # (a parked `decision` waiting to be promoted looks identical to a dropped
  # one). Only two upstream facts justify closing a local task:
  #
  #   * the issue is actually closed upstream, or
  #   * it is genuinely assigned to somebody other than the viewer.
  #
  # Everything else — unassigned, or a `fetch` we could not complete — returns
  # `nil` and produces no action at all, so neither a quiet board nor a
  # transient API failure can bulk-close live work. Under-closing is visible
  # and cheap to correct by hand; over-closing silently destroys open work.
  defp close_reason(adapter, ref, current_user_id) do
    case adapter.fetch(ref) do
      {:ok, issue} ->
        # Compare against the viewer explicitly: an issue still assigned to us
        # that merely failed to show up in `list_open` (paging, index lag) is
        # not a reassignment.
        others = adapter.assignees(issue) -- [current_user_id]

        cond do
          adapter.issue_status(issue) == :closed ->
            "tracker issue #{ref} closed"

          others != [] ->
            "tracker issue #{ref} reassigned to #{Enum.join(others, ", ")}"

          true ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  # bd-2wilou: a task closed locally whose linked tracker issue is still open
  # means a close never propagated upstream (or propagated and was later
  # reopened by a human — either way it's drift worth surfacing). Scans every
  # closed task with a `tracker_ref`, independent of current assignment,
  # since the issue may no longer be assigned to the viewer by the time this
  # runs.
  #
  # bd-83ojwi/bd-bsco7f: but only for closes that were meant to take the ticket
  # with them — see `close_meant_to_propagate?/1`. A findings-only close never
  # made that claim, so its ticket staying open is the expected outcome, not
  # drift.
  defp build_drift(adapter, workspace, type) do
    workspace
    |> read_closed_tracker_tasks(type)
    |> Enum.filter(&close_meant_to_propagate?/1)
    |> Enum.flat_map(fn task ->
      case adapter.fetch(task.tracker_ref) do
        {:ok, issue} ->
          if adapter.issue_status(issue) == :closed do
            []
          else
            [
              {:drift, task.id,
               "task closed locally but tracker issue #{task.tracker_ref} is still open"}
            ]
          end

        {:error, _} ->
          []
      end
    end)
  end

  # bd-83ojwi: was this local close supposed to leave the tracker ticket
  # closed? When it wasn't, the ticket staying open is the intended outcome and
  # reporting it invites a "reconciliation" that closes a live ticket and
  # destroys the handoff notes it carries.
  #
  # Two shapes are exempt outright:
  #
  #   * `:task`-type — the opt-in non-reviewable research/investigation type
  #     (see `Issue.issue_type`). Its deliverable is a findings summary in
  #     `notes`: no diff, no PR. Closing one records that the *investigation*
  #     finished, not that the underlying work is done.
  #   * `review_only` — a borrowed ticket this task never owned. SyncTracker
  #     refuses to transition it (bd-6xaaam), so it is open by construction.
  #
  # Past that, bd-83ojwi asked whether the close shipped a diff, using `pr_ref`
  # as the stand-in. bd-bsco7f keeps that limb and adds the signal it was
  # standing in for. `close_upstream_expected` (recorded at close time by
  # `Issue.Changes.RecordCloseIntent`) says outright whether the close was meant
  # to propagate, which catches the case `pr_ref` cannot see: a `bug` fixed by
  # hand or as a drive-by, closed with `close_upstream: true`, whose upstream
  # close then failed. No PR was ever opened, so bd-83ojwi's gate read it as a
  # findings-only close and said nothing — the bd-2wilou class arriving by the
  # manual path.
  #
  # Both limbs are needed, and neither subsumes the other:
  #
  #   * intent alone would drop the Jira merge path, which closes with
  #     `close_upstream: false` on purpose (the `:merged` lifecycle already
  #     moved the ticket to Code Complete — see `MergeQueue.close_task_and_finalize`)
  #     yet very much expects the ticket not to be left open.
  #   * `pr_ref` alone is bd-83ojwi's blind spot, and it is the only signal
  #     available for rows closed before the intent was recorded (`nil`), where
  #     it stays the fallback. That is what keeps the live findings-only closes
  #     vs-9y1ipo/sc-619 and vs-bdix5z/sc-485 unflagged.
  defp close_meant_to_propagate?(%Issue{issue_type: :task}), do: false
  defp close_meant_to_propagate?(%Issue{review_only: true}), do: false
  defp close_meant_to_propagate?(%Issue{close_upstream_expected: true}), do: true

  defp close_meant_to_propagate?(%Issue{pr_ref: pr_ref}) when is_binary(pr_ref),
    do: String.trim(pr_ref) != ""

  defp close_meant_to_propagate?(_task), do: false

  defp read_closed_tracker_tasks(workspace, type) do
    query =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace.id and tracker_type == ^type and status == :closed and
          not is_nil(tracker_ref)
      )

    case Ash.read(query) do
      {:ok, list} -> list
      _ -> []
    end
  end

  defp action_order({:create, a, _}, {:create, b, _}), do: a <= b
  defp action_order({:close, a, _}, {:close, b, _}), do: a <= b
  defp action_order({:drift, a, _}, {:drift, b, _}), do: a <= b
  defp action_order({:create, _, _}, _), do: true
  defp action_order(_, {:create, _, _}), do: false
  defp action_order({:close, _, _}, {:drift, _, _}), do: true
  defp action_order({:drift, _, _}, {:close, _, _}), do: false

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
           Ash.update(task, %{reason: reason, close_upstream: false}, action: :close) do
      {:closed, closed}
    else
      {:error, reason} -> {:error, action, reason}
    end
  end

  # Report-only: a `:drift` action never writes to the local task. Fixing
  # drift means propagating the close upstream (`task_sync_upstream_close`),
  # not mutating the task that's already correctly closed locally.
  defp apply_action(_workspace, {:drift, task_id, _reason} = action) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> {:drifted, task}
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
