defmodule Arbiter.Tasks.Issue.Changes.CleanupWorktree do
  @moduledoc """
  After-action hook for the `:close` action: if a git worktree exists for
  this task, remove it.

  Path is derived from the task via `Arbiter.Worker.BranchNamer.derive/1`
  + `Arbiter.Worker.Worktree.worktree_path/1` — the same convention
  `Dispatch` uses on provisioning, so we never need a stored path.

  Two paths are reclaimed, both derived from the same branch name:

    * the **branch** worktree (`Worktree.worktree_path/1`) — a code dispatch's
      checkout, which may hold uncommitted or unpushed work, so removal is
      skipped when it is dirty;
    * the **inspect** worktree (`Worktree.inspect_path/1`, bd-9r1tta) — the
      detached checkout a `task`-type audit/spike runs in. Nothing there is
      meant to be preserved (no branch, so nothing unpushed; the agent's
      deliverable is `notes`), so it is removed even when dirty. Leaving it
      would leak a worktree per audited bead, which is the cost of giving the
      inspect checkout its own leaf.

  Best-effort. Skipped silently when:

    * no directory exists at the derived path,
    * the branch worktree has uncommitted changes (a warning is logged so the
      operator notices a manual cleanup is needed),
    * `BranchNamer.derive/1` cannot produce a branch (e.g. legacy tasks
      with unrecognised issue types).

  Failures from `Worktree.cleanup/1` are logged but never propagated — the
  `:close` action must succeed even if teardown does not.

  Pairs with `Arbiter.Tasks.Issue.Changes.StopWorker`, which handles the
  in-memory side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Worktree

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      try do
        cleanup(issue)
      rescue
        e ->
          Logger.warning("CleanupWorktree: error for task=#{issue.id}: #{Exception.message(e)}")
      catch
        :exit, reason ->
          Logger.warning("CleanupWorktree: exit for task=#{issue.id}: #{inspect(reason)}")
      end

      {:ok, issue}
    end)
  end

  defp cleanup(issue) do
    case branch_for(issue) do
      nil ->
        :ok

      branch ->
        remove_branch_worktree(issue, Worktree.worktree_path(branch))
        remove_inspect_worktree(issue, Worktree.inspect_path(branch))
        :ok
    end
  end

  defp remove_branch_worktree(issue, path) do
    cond do
      not File.dir?(path) ->
        :ok

      dirty?(path, issue.id) ->
        Logger.warning(
          "CleanupWorktree: worktree has uncommitted changes for task=#{issue.id}; skipping removal at #{path}"
        )

        :ok

      true ->
        remove(issue, path)
    end
  end

  # No dirty-check: a detached inspect checkout has no branch and holds no
  # deliverable, so scratch files in it are not work to preserve (bd-9r1tta).
  defp remove_inspect_worktree(issue, path) do
    if File.dir?(path), do: remove(issue, path), else: :ok
  end

  defp remove(issue, path) do
    case Worktree.cleanup(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: removal failed for task=#{issue.id} at #{path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp branch_for(issue) do
    BranchNamer.derive(issue)
  rescue
    ArgumentError ->
      # BranchNamer rejects tasks with unknown issue_type or missing
      # title+id — those predate per-task branching and have no worktree
      # to clean up.
      nil
  end

  defp dirty?(path, task_id) do
    case Worktree.has_uncommitted?(path) do
      {:ok, dirty?} ->
        dirty?

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: dirty-probe failed for task=#{task_id} at #{path}: #{inspect(reason)}"
        )

        # Conservative: treat probe failure as "might be dirty" — skip cleanup.
        true
    end
  end
end
