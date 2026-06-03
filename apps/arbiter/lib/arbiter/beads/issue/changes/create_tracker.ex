defmodule Arbiter.Beads.Issue.Changes.CreateTracker do
  @moduledoc """
  After-transaction hook for `Issue.create`: when the new bead has a tracker
  (`tracker_type != :none`) and no `tracker_ref` was supplied, mirror it to
  the configured upstream tracker and persist the returned ref back onto the
  bead.

  Skips entirely when:

    * `tracker_type == :none` (no tracker to mirror to), OR
    * `tracker_ref` is already populated (caller supplied `--tracker-ref N`
      to bind to an existing upstream item).

  ## Why `after_transaction`, not `after_action`

  `after_action` hooks run *inside* the create transaction — returning
  `{:error, _}` from one would roll the bead back. The spec requires the
  opposite: a tracker failure must leave the bead intact while still
  surfacing a non-zero exit to the CLI. `after_transaction` fires *after*
  the row is committed, so an error there propagates to the caller without
  un-creating the bead.

  ## Why a follow-up `Ash.update`

  We write the returned ref via a separate `:update` call rather than
  pre-staging it on the create changeset because we don't know the ref until
  the upstream call returns — which happens after the create transaction
  has committed. `SyncTracker` on `:update` is a no-op when status doesn't
  change, so this doesn't fire a redundant adapter call.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _cs, result ->
      case result do
        {:ok, issue} -> maybe_create_upstream(issue)
        other -> other
      end
    end)
  end

  defp maybe_create_upstream(%{tracker_type: :none} = issue), do: {:ok, issue}

  defp maybe_create_upstream(%{tracker_ref: ref} = issue)
       when is_binary(ref) and ref != "" do
    {:ok, issue}
  end

  defp maybe_create_upstream(issue) do
    workspace = load_workspace(issue.workspace_id)

    attrs =
      %{title: issue.title}
      |> maybe_put(:description, issue.description)
      |> maybe_put(:assignee, issue.assignee)
      |> Map.put(:status, issue.status)

    case Trackers.create(issue.tracker_type, workspace, attrs) do
      {:ok, ref} ->
        bind_ref(issue, ref)

      {:error, %{kind: :not_implemented} = reason} ->
        # Adapter stub: outbound create isn't wired up for this tracker yet.
        # Treat exactly like a local-only create — bead stays unlinked, no
        # error surfaced (use `arb create --tracker-ref` to bind manually).
        Logger.info(
          "CreateTracker: skipping outbound create for bead=#{issue.id} " <>
            "tracker=#{issue.tracker_type} (not implemented): " <>
            inspect(reason)
        )

        {:ok, issue}

      {:error, reason} ->
        Logger.warning(
          "CreateTracker: failed to mirror bead=#{issue.id} " <>
            "tracker=#{issue.tracker_type}: #{inspect(reason)}"
        )

        {:error, format_error(issue, reason)}
    end
  rescue
    e ->
      Logger.warning(
        "CreateTracker: error mirroring bead=#{issue.id}: #{Exception.message(e)}"
      )

      {:error, format_error(issue, e)}
  end

  defp bind_ref(issue, ref) do
    case Ash.update(issue, %{tracker_ref: ref}, action: :update) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, reason} ->
        Logger.warning(
          "CreateTracker: upstream issue #{ref} created but failed to bind " <>
            "to bead=#{issue.id}: #{inspect(reason)}"
        )

        {:error,
         Arbiter.Beads.Issue.CreateTrackerError.exception(
           bead_id: issue.id,
           tracker_type: issue.tracker_type,
           upstream_ref: ref,
           reason: reason,
           message:
             "bead #{issue.id} created and upstream issue #{ref} created, " <>
               "but failed to persist tracker_ref on the bead: #{inspect(reason)}"
         )}
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error(issue, reason) do
    Arbiter.Beads.Issue.CreateTrackerError.exception(
      bead_id: issue.id,
      tracker_type: issue.tracker_type,
      upstream_ref: nil,
      reason: reason
    )
  end
end
