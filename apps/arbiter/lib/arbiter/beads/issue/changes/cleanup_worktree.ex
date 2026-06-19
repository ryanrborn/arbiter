defmodule Arbiter.Beads.Issue.Changes.CleanupWorktree do
  @moduledoc """
  After-action hook for the `:close` action: if a git worktree exists for
  this bead, remove it.

  Path is derived from the bead via `Arbiter.Polecat.BranchNamer.derive/1`
  + `Arbiter.Polecat.Worktree.worktree_path/1` — the same convention
  `Dispatch` uses on provisioning, so we never need a stored path.

  Best-effort. Skipped silently when:

    * no directory exists at the derived path,
    * the worktree has uncommitted changes (a warning is logged so the
      operator notices a manual cleanup is needed),
    * `BranchNamer.derive/1` cannot produce a branch (e.g. legacy beads
      with unrecognised issue types).

  Failures from `Worktree.cleanup/1` are logged but never propagated — the
  `:close` action must succeed even if teardown does not.

  Pairs with `Arbiter.Beads.Issue.Changes.StopPolecat`, which handles the
  in-memory side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Polecat.BranchNamer
  alias Arbiter.Polecat.Worktree

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      try do
        cleanup(issue)
      rescue
        e ->
          Logger.warning("CleanupWorktree: error for bead=#{issue.id}: #{Exception.message(e)}")
      catch
        :exit, reason ->
          Logger.warning("CleanupWorktree: exit for bead=#{issue.id}: #{inspect(reason)}")
      end

      {:ok, issue}
    end)
  end

  defp cleanup(issue) do
    case worktree_path_for(issue) do
      nil ->
        :ok

      path ->
        cond do
          not File.dir?(path) ->
            :ok

          dirty?(path, issue.id) ->
            Logger.warning(
              "CleanupWorktree: worktree has uncommitted changes for bead=#{issue.id}; skipping removal at #{path}"
            )

            :ok

          true ->
            case Worktree.cleanup(path) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "CleanupWorktree: removal failed for bead=#{issue.id} at #{path}: #{inspect(reason)}"
                )

                :ok
            end
        end
    end
  end

  defp worktree_path_for(issue) do
    branch = BranchNamer.derive(issue)
    Worktree.worktree_path(branch)
  rescue
    ArgumentError ->
      # BranchNamer rejects beads with unknown issue_type or missing
      # title+id — those predate per-bead branching and have no worktree
      # to clean up.
      nil
  end

  defp dirty?(path, bead_id) do
    case Worktree.has_uncommitted?(path) do
      {:ok, dirty?} ->
        dirty?

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: dirty-probe failed for bead=#{bead_id} at #{path}: #{inspect(reason)}"
        )

        # Conservative: treat probe failure as "might be dirty" — skip cleanup.
        true
    end
  end
end
