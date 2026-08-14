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

  Liveness guard (bd-bmmj4w): git status alone cannot prove a worktree is
  safe to delete — a clean, fully-pushed worktree can still have a live
  sub-worker (`:fixpass`, `#review`, ...) mid-`mix test` inside it, and
  removing it then destroys the directory out from under a running process.

  The guard has two halves, and it is the pair that makes it sound:

    * `Worker.terminate/2` SIGKILLs the agent's OS process **and its
      descendants** before the worker GenServer finishes dying. Erlang does
      not reap a `:spawn_executable` port's OS process on owner death, so
      without that half a stopped worker still leaves a live `claude` (and
      its `mix test` child) running in the worktree, and no registry check
      could see it.
    * This hook then waits (briefly) for every worker registered under this
      task to actually leave the registry, because `StopWorker` — which runs
      immediately before it — uses a *bounded* per-worker stop and may return
      while a worker is still mid-`terminate/2`. If any is still alive when
      the grace window closes, both removals are skipped with a warning, same
      as the dirty path.

  So what this hook checks directly is "no worker GenServer for this task is
  still registered and alive"; that stands in for "no agent still owns the
  directory" only because of the first half above. It is not a general
  live-process probe of the directory, and two residual cases stay invisible
  to it:

    * a process that never belonged to a worker at all — an operator's own
      shell sitting in the worktree, say;
    * an *orphaned* agent, whose worker died without `terminate/2` running
      (`Process.exit(pid, :kill)`, or a linked exit — `Worker` does not trap
      exits). Nothing killed its OS process, and the registry row for the
      dead worker is filtered out by `live_for/1` as a corpse, so the drain
      reports `:drained` while the agent is still running in the directory.
      Every path that stops a worker deliberately (`Worker.stop/3`, and so
      `StopWorker`) goes through `GenServer.stop`, which always runs
      `terminate/2` — so this is the abnormal-kill case, not the `:close`
      path the incident came from. Closing it would take an OS-level probe
      of the directory (`/proc/*/cwd`, `lsof`), which is platform-specific;
      it is deliberately out of scope here.

  Failures from `Worktree.cleanup/1` are logged but never propagated — the
  `:close` action must succeed even if teardown does not.

  Pairs with `Arbiter.Tasks.Issue.Changes.StopWorker`, which handles the
  in-memory side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Arbiter.Worker.Worktree

  @drain_poll_ms 50

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
        branch_path = Worktree.worktree_path(branch)
        inspect_path = Worktree.inspect_path(branch)

        # Only pay the drain wait when there is actually something to remove.
        if File.dir?(branch_path) or File.dir?(inspect_path) do
          case await_worker_drain(issue.id) do
            :drained ->
              remove_branch_worktree(issue, branch_path)
              remove_inspect_worktree(issue, inspect_path)

            {:live, registry_keys} ->
              Logger.warning(
                "CleanupWorktree: live worker(s) still registered for task=#{issue.id} " <>
                  "(#{Enum.join(registry_keys, ", ")}); skipping worktree removal"
              )
          end
        end

        :ok
    end
  end

  # A filesystem-destroying operation must not trust that StopWorker (which
  # runs just before this hook, with a bounded per-worker stop) fully drained
  # every worker owned by this task: re-check liveness here, giving a worker
  # that is mid-terminate a short grace window to actually exit. Returns
  # `:drained` once no live worker remains registered under the task, or
  # `{:live, registry_keys}` when the window closes with some still alive —
  # in which case the caller skips removal entirely (bd-bmmj4w).
  defp await_worker_drain(task_id) do
    deadline = System.monotonic_time(:millisecond) + drain_ms()
    await_worker_drain(task_id, deadline)
  end

  defp await_worker_drain(task_id, deadline) do
    # `live_for/1` (not `all_for/1`) so an unreaped registry corpse — a worker
    # that died without terminate/2 running, whose row Registry clears
    # asynchronously — cannot block cleanup forever.
    case WorkerRegistry.live_for(task_id) do
      [] ->
        :drained

      live ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:live, Enum.map(live, fn {registry_key, _pid} -> registry_key end)}
        else
          Process.sleep(@drain_poll_ms)
          await_worker_drain(task_id, deadline)
        end
    end
  end

  defp drain_ms do
    Application.get_env(:arbiter, :cleanup_worktree_drain_ms, 2_000)
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
