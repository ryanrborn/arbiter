defmodule Arbiter.Trackers.Sync do
  @moduledoc """
  Loud, escalation-raising orchestration for external-tracker lifecycle sync.

  Two entry points, both tracker-agnostic:

    * `lifecycle/3` — drive a richer lifecycle moment that isn't a task status
      change (PR opened, review approved-but-parked). It seeds the adapter
      config from the task's workspace, transitions the external item toward
      the mapped target status (multi-hop path-finding lives in the adapter),
      and — for `:pr_opened` — attaches the PR as a comment + remote link.

    * `notify_failure/3` — the shared failure surface. The original incident
      (VR-17911 never auto-transitioned) was invisible because tracker errors
      were silently swallowed. This logs loudly **and** raises an
      escalation so a `status_map` / workflow mismatch can't hide.

  ## Benign vs. loud

  Not every non-`:ok` is a problem. A tracker that simply doesn't model a given
  lifecycle event (e.g. GitHub has no "In Code Review") returns
  `:status_unmapped` / `:transition_not_found` / `:not_supported` — we skip
  quietly. A *mapped* status that can't be reached (`:no_transition_path`) or a
  real wire failure (auth, 5xx, network) is loud + escalation. See `loud?/1`.
  """

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.AdmiralNotifier
  alias Arbiter.Trackers

  @doc """
  Drive a lifecycle event for the task's external tracker. Best-effort and
  always returns `:ok` — failures are logged + escalated, never raised, so the
  caller's own lifecycle is never disrupted.

  Recognised `opts`:
    * `:pr_url` — the PR/MR URL, used for the `:pr_opened` comment + remote link.
    * `:pr_title` — optional label for the remote link (defaults from `:pr_url`).
  """
  @spec lifecycle(Issue.t(), atom(), keyword()) :: :ok
  def lifecycle(%Issue{} = issue, event, opts \\ []) when is_atom(event) do
    cond do
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      true -> do_lifecycle(issue, event, opts)
    end
  rescue
    e ->
      Logger.warning(
        "Trackers.Sync: error on #{event} for task=#{issue.id}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("Trackers.Sync: exit on #{event} for task=#{issue.id}: #{inspect(reason)}")
      :ok
  end

  defp do_lifecycle(issue, event, opts) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))

    transition_event(issue, event)

    if event == :pr_opened, do: attach_pr_artifacts(issue, opts)

    :ok
  end

  @doc """
  Transition the task's external item toward the status mapped from `event`,
  surfacing any genuine failure loudly (log + escalation). Returns `:ok` on
  success or a benign skip, `{:error, reason}` only after escalating a loud
  failure (so callers that care can react; most ignore it).

  Used by `lifecycle/3` and by `Arbiter.Tasks.Issue.Changes.SyncTracker` for
  the core status-change path so the swallow-on-error behaviour is gone from
  both.
  """
  @spec transition_event(Issue.t(), atom()) :: :ok | {:error, term()}
  def transition_event(%Issue{} = issue, event) when is_atom(event) do
    case Trackers.transition(issue, event) do
      :ok ->
        :ok

      {:error, reason} ->
        if loud?(reason) do
          notify_failure(issue, event, reason)
          {:error, reason}
        else
          Logger.debug(
            "Trackers.Sync: #{event} not modelled by tracker=#{issue.tracker_type} " <>
              "for task=#{issue.id} (#{describe(reason)}) — skipping"
          )

          :ok
        end
    end
  end

  @doc """
  Log loudly and raise an escalation for a tracker-sync failure. The
  single place a swallowed-error regression would have to get past.
  """
  @spec notify_failure(Issue.t(), atom(), term()) :: :ok
  def notify_failure(%Issue{} = issue, event, reason) do
    Logger.error(
      "Trackers.Sync: FAILED to sync task=#{issue.id} tracker=#{issue.tracker_type} " <>
        "ref=#{issue.tracker_ref} on #{event}: #{describe(reason)} — raising escalation. " <>
        "Reconcile the workspace status_map / transition_graph with the tracker workflow."
    )

    AdmiralNotifier.tracker_sync_failed(
      %{
        task_id: issue.id,
        workspace_id: issue.workspace_id,
        tracker_type: issue.tracker_type,
        tracker_ref: issue.tracker_ref
      },
      event,
      reason
    )

    :ok
  end

  # ---- PR-open artifacts ---------------------------------------------------

  # PR-open: comment the PR URL onto the ticket and attach it as a remote link.
  # Both are tracker-agnostic (adapters that don't support them return
  # `:not_supported`, which we skip). A genuine wire failure is loud.
  defp attach_pr_artifacts(issue, opts) do
    case Keyword.get(opts, :pr_url) do
      url when is_binary(url) and url != "" ->
        title = Keyword.get(opts, :pr_title) || "PR for #{issue.id}"
        comment_pr(issue, url)
        link_pr(issue, url, title)

      _ ->
        :ok
    end
  end

  defp comment_pr(issue, url) do
    body = "Arbiter opened a pull request for this ticket: #{url}"

    case Trackers.add_comment(issue, body) do
      :ok ->
        :ok

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        if loud?(reason), do: notify_failure(issue, :pr_comment, reason), else: :ok
    end
  end

  defp link_pr(issue, url, title) do
    case Trackers.add_remote_link(issue, url, title) do
      :ok ->
        :ok

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        if loud?(reason), do: notify_failure(issue, :pr_remote_link, reason), else: :ok
    end
  end

  # ---- classification ------------------------------------------------------

  @benign_kinds ~w(status_unmapped transition_not_found not_supported config_missing)a

  @doc false
  # A failure worth an escalation vs. a benign "this tracker doesn't model it" skip.
  def loud?(:not_supported), do: false
  def loud?(%{kind: kind}) when kind in @benign_kinds, do: false
  def loud?(_), do: true

  defp describe(%{__struct__: _, message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe(reason), do: inspect(reason)

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
