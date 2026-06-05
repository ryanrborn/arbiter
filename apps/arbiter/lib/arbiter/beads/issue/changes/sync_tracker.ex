defmodule Arbiter.Beads.Issue.Changes.SyncTracker do
  @moduledoc """
  After-action hook for the status-changing actions (`:update`, `:close`,
  `:reopen`): propagate the new bead status to the linked external tracker.

  Fires only when **all** of these hold:

    * the status actually changed (old != new),
    * the bead has a tracker (`tracker_type != :none`), and
    * the bead carries a `tracker_ref`.

  When it fires, it seeds the per-process tracker config from the bead's
  workspace (`Arbiter.Trackers.prepare/2`) and calls the resolved adapter's
  `transition/2`, mapping the bead status to the external state via the
  adapter's own `status_map` (e.g. GitHub `:closed -> "closed"`,
  `:open`/`:in_progress -> "open"`).

  ## Gated forward transition (Jira / LeoTech)

  Some trackers gate the forward (closing) transition on custom fields being
  populated — LeoTech's Jira (Verus / VR) refuses to move a ticket forward
  until its "QA Testing Notes" and "Deployment Notes" fields are filled. So
  before a `:closed` transition on a gated tracker we:

    1. **Gate-check** the bead's `qa_notes` + `deployment_notes`. If either is
       blank we log a clear, actionable error and **skip** the transition
       entirely — rather than firing a transition Jira would reject for empty
       fields. The notes are produced as an explicit completion step of
       tracker-backed work (see the work prompt in `Arbiter.Polecat.Sling`).
    2. **Push** the notes via `Arbiter.Trackers.update_fields/2` (Markdown →
       ADF is handled by the Jira adapter), so the gated fields are filled
       *before* the transition is attempted.
    3. **Transition** the ticket.

  Non-closing transitions (`open ⇄ in_progress`, reopen) never touch the
  custom fields.

  Best-effort: a sync failure is logged and swallowed — the local transition
  must succeed even when the external tracker is unreachable or misconfigured.
  Mirrors the teardown pattern in `Arbiter.Beads.Issue.Changes.StopPolecat`.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, issue ->
      close_upstream = Ash.Changeset.get_argument(cs, :close_upstream)
      maybe_sync(cs.data.status, issue, cs.action.name, close_upstream)
      {:ok, issue}
    end)
  end

  defp maybe_sync(old_status, issue, action_name, close_upstream) do
    cond do
      old_status == issue.status -> :ok
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      action_name == :close and not close_upstream -> :ok
      true -> sync(issue)
    end
  end

  defp sync(issue) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))

    case ensure_completion_notes_pushed(issue) do
      :ok ->
        do_transition(issue)

      {:error, %{gate: true, message: message}} ->
        # The gated tracker would reject this forward transition for empty
        # custom fields. Surface a clear, actionable error and DON'T attempt
        # the transition — a blocked/failed transition is worse than a
        # skipped one the operator can retry after filling the notes.
        Logger.error(
          "SyncTracker: gated transition BLOCKED for bead=#{issue.id} " <>
            "tracker=#{issue.tracker_type} ref=#{issue.tracker_ref}: #{message} " <>
            "Skipping the forward transition. Populate qa_notes + deployment_notes " <>
            "on the bead (e.g. `arb update #{issue.id} --qa-notes ... --deployment-notes ...`) " <>
            "and re-run the sync."
        )

      {:error, reason} ->
        # Pushing the notes failed (network/auth/etc). Skip the transition
        # rather than fire it into a gate that would reject it anyway.
        Logger.warning(
          "SyncTracker: failed to push completion notes for bead=#{issue.id} " <>
            "tracker=#{issue.tracker_type} ref=#{issue.tracker_ref}: #{inspect(reason)} " <>
            "— skipping the gated transition."
        )
    end
  rescue
    e ->
      Logger.warning("SyncTracker: error syncing bead=#{issue.id}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("SyncTracker: exit syncing bead=#{issue.id}: #{inspect(reason)}")
  end

  defp do_transition(issue) do
    case Trackers.transition(issue, issue.status) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SyncTracker: failed to sync bead=#{issue.id} " <>
            "tracker=#{issue.tracker_type} ref=#{issue.tracker_ref} " <>
            "-> #{issue.status}: #{inspect(reason)}"
        )
    end
  end

  # Only the forward (closing) transition is gated; open ⇄ in_progress and
  # reopen never touch the gated custom fields. For non-gated trackers
  # (GitHub, None, …) there is nothing to push and no gate to honor.
  defp ensure_completion_notes_pushed(%{status: :closed} = issue) do
    if gated_tracker?(issue.tracker_type) do
      push_gated_notes(issue)
    else
      :ok
    end
  end

  defp ensure_completion_notes_pushed(_issue), do: :ok

  # Trackers whose forward transition is gated on populated completion notes.
  defp gated_tracker?(:jira), do: true
  defp gated_tracker?(_), do: false

  defp push_gated_notes(issue) do
    qa = issue.qa_notes
    deploy = issue.deployment_notes

    cond do
      blank?(qa) and blank?(deploy) ->
        {:error, gate_error("QA Notes and Deployment Notes are both empty")}

      blank?(qa) ->
        {:error, gate_error("QA Notes is empty")}

      blank?(deploy) ->
        {:error, gate_error("Deployment Notes is empty")}

      true ->
        Trackers.update_fields(issue, %{qa_notes: qa, deployment_notes: deploy})
    end
  end

  defp gate_error(what) do
    %{
      gate: true,
      message: what <> " — the tracker requires both before a forward transition."
    }
  end

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
