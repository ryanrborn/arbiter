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

  ## Already-at-target-state recovery

  A `:validation_failed` from the tracker is normally loud, but it can be a
  benign race: e.g. GitHub auto-closes an issue via a `Closes #N` keyword
  between Arbiter's pre-flight GET (which saw "open") and the subsequent PATCH.
  `do_transition/2` re-fetches the upstream item after a `validation_failed` and
  suppresses the escalation if the item is already at the desired state — the
  transition was a no-op, not a real failure.
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
    case ensure_gated_fields_pushed(issue, event) do
      :ok ->
        do_transition(issue, event)

      {:error, reason} ->
        # Either a required field has no produced value (escalate naming it) or
        # pushing the produced values failed on the wire. Both are loud, and we
        # do NOT attempt the transition the provider would reject anyway.
        notify_failure(issue, event, reason)
        {:error, reason}
    end
  end

  defp do_transition(issue, event) do
    case Trackers.transition(issue, event) do
      :ok ->
        :ok

      {:error, %{kind: :validation_failed} = reason} ->
        # A validation_failed can be a race: e.g. GitHub auto-closed the issue via a
        # `Closes #N` keyword between our GET (which saw "open") and our PATCH. The
        # tracker rejects the redundant transition, but the desired end-state is already
        # reached. Re-fetch to confirm before escalating.
        if already_at_target?(issue, event) do
          Logger.debug(
            "Trackers.Sync: #{event} for task=#{issue.id} " <>
              "tracker=#{issue.tracker_type} ref=#{issue.tracker_ref} — " <>
              "upstream already at target state (benign no-op)"
          )

          :ok
        else
          notify_failure(issue, event, reason)
          {:error, reason}
        end

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

  # Fetch the upstream item and check whether it's already at the desired state
  # for `event`. Returns false on fetch failure so genuine unreachable-tracker
  # errors still escalate.
  defp already_at_target?(issue, event) do
    case Trackers.fetch(issue) do
      {:ok, raw} -> upstream_at_target?(issue.tracker_type, event, raw)
      {:error, _} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp upstream_at_target?(:github, :closed, %{"state" => "closed"}), do: true
  defp upstream_at_target?(:gitlab, :closed, %{"state" => "closed"}), do: true

  defp upstream_at_target?(:jira, :closed, raw) do
    get_in(raw, ["fields", "status", "statusCategory", "key"]) == "done"
  end

  defp upstream_at_target?(:shortcut, :closed, %{"completed" => true}), do: true
  defp upstream_at_target?(_, _, _), do: false

  # Push the bead's produced field values into the transition's gating fields
  # BEFORE the transition is attempted. The adapter (not this layer) decides
  # which fields gate the transition — see `Tracker.gating_fields/2` — so this
  # stays provider-agnostic: Jira's `field_ids` today, any future tracker via
  # its own adapter.
  #
  #   * No gate (`{:ok, []}`) → nothing to push, proceed to transition.
  #   * A required field with no produced value on the bead → `{:error, ...}`
  #     naming the exact field (escalated by the caller).
  #   * All required fields have produced values → push them, then transition.
  #
  # A benign adapter reason (e.g. `:status_unmapped` — the tracker doesn't model
  # this event, so there's no transition to gate) is treated as "no gate"; the
  # transition path then skips it quietly.
  defp ensure_gated_fields_pushed(issue, event) do
    case Trackers.gating_fields(issue, event) do
      {:ok, []} ->
        :ok

      {:ok, fields} ->
        push_resolved_fields(issue, fields)

      {:error, reason} ->
        if loud?(reason), do: {:error, reason}, else: :ok
    end
  end

  defp push_resolved_fields(issue, fields) do
    {present, missing} =
      Enum.split_with(fields, fn f -> not blank?(produced_value(issue, f.key)) end)

    cond do
      missing != [] ->
        {:error, missing_fields_reason(missing)}

      present == [] ->
        :ok

      true ->
        values = Map.new(present, fn f -> {f.key, produced_value(issue, f.key)} end)

        case Trackers.update_fields(issue, values) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The bead carries the worker-produced values under task-domain keys
  # (`:qa_notes`, `:deployment_notes`, `:description`, ...). A gating field with
  # no task-domain key (`nil`) has no produced value by definition.
  defp produced_value(_issue, nil), do: nil
  defp produced_value(issue, key) when is_atom(key), do: Map.get(issue, key)

  defp missing_fields_reason(missing) do
    names = missing |> Enum.map(& &1.name) |> Enum.uniq()

    %{
      kind: :gated_fields_missing,
      missing_fields: names,
      message:
        "the tracker gates this transition on field(s) the bead hasn't produced: " <>
          "#{Enum.join(names, ", ")}. Produce the value(s) on the task " <>
          "(e.g. qa_notes / deployment_notes) and re-run the sync"
    }
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
        log_hint(reason)
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

  defp describe(%{message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe(reason), do: inspect(reason)

  # The describe/1 message already names the missing field and the remedy for a
  # gated-fields failure, so don't append the (misleading) status_map hint.
  defp log_hint(%{kind: :gated_fields_missing}), do: ""

  # Provider's real error is already in the describe/1 output; appending the
  # config hint here would be actively misleading.
  defp log_hint(%{kind: :validation_failed}), do: ""
  defp log_hint(%{kind: :unauthenticated}), do: ""
  defp log_hint(%{kind: :forbidden}), do: ""
  defp log_hint(%{kind: :server_error}), do: ""
  defp log_hint(%{kind: :network}), do: ""

  # No path through the graph IS a config-mismatch — keep the hint.
  defp log_hint(%{kind: :no_transition_path}),
    do: "Reconcile the workspace status_map / transition_graph with the tracker workflow."

  defp log_hint(_reason),
    do: "Reconcile the workspace status_map / transition_graph with the tracker workflow."

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
