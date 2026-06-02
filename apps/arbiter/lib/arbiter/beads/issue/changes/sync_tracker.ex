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
      maybe_sync(cs.data.status, issue)
      {:ok, issue}
    end)
  end

  defp maybe_sync(old_status, issue) do
    cond do
      old_status == issue.status -> :ok
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      true -> sync(issue)
    end
  end

  defp sync(issue) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))

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
  rescue
    e ->
      Logger.warning("SyncTracker: error syncing bead=#{issue.id}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("SyncTracker: exit syncing bead=#{issue.id}: #{inspect(reason)}")
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
