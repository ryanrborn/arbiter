defmodule Arbiter.Beads.Issue.Changes.SyncFields do
  @moduledoc """
  After-action hook for the `:update` action: propagate `title` and/or
  `description` changes to the linked external tracker.

  Fires only when **all** of these hold:

    * at least one of `[:title, :description]` actually changed,
    * the bead has a tracker (`tracker_type != :none`), and
    * the bead carries a `tracker_ref`.

  Best-effort: a sync failure is logged and swallowed — the local update must
  succeed even when the external tracker is unreachable or misconfigured.
  Mirrors the teardown pattern in `Arbiter.Beads.Issue.Changes.SyncTracker`.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers

  @tracked_fields [:title, :description]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, issue ->
      changed = changed_fields(cs.data, issue)
      maybe_sync(issue, changed)
      {:ok, issue}
    end)
  end

  defp changed_fields(original, updated) do
    Enum.reduce(@tracked_fields, %{}, fn field, acc ->
      old_val = Map.get(original, field)
      new_val = Map.get(updated, field)

      if old_val != new_val do
        Map.put(acc, field, new_val)
      else
        acc
      end
    end)
  end

  defp maybe_sync(_issue, changed) when map_size(changed) == 0, do: :ok

  defp maybe_sync(%{tracker_type: :none}, _changed), do: :ok

  defp maybe_sync(%{tracker_ref: ref}, _changed) when is_nil(ref) or ref == "", do: :ok

  defp maybe_sync(issue, changed) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))

    case Trackers.update_fields(issue, changed) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SyncFields: failed to sync fields #{inspect(Map.keys(changed))} " <>
            "for bead=#{issue.id} tracker=#{issue.tracker_type} " <>
            "ref=#{issue.tracker_ref}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning("SyncFields: error syncing bead=#{issue.id}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("SyncFields: exit syncing bead=#{issue.id}: #{inspect(reason)}")
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end
end
