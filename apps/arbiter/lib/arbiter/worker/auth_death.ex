defmodule Arbiter.Worker.AuthDeath do
  @moduledoc """
  What happens to a task whose worker died with `:auth_expired` (bd-21bmdh).

  Before this, `Arbiter.Worker.fail_stopped/2` failed the worker, escalated,
  and left the task `:in_progress` behind a `:failed` worker — nothing ever
  returned it to Ready. That was tolerable while a live pre-flight probe
  caught dead credentials before dispatch. bd-2jgs2h retired that probe, so
  an auth death at spawn is now the normal way the fleet finds out, and
  every blip would need a manual reopen. The operator approved the change on
  2026-09-18: **an auth-failed task goes back to Ready**, behind the
  per-provider `Arbiter.Agents.AuthHold`, so it is retried once credentials
  recover instead of stranded. The hold is what keeps this from becoming a
  loop — see its moduledoc.

  `Arbiter.Worker.Driver` calls `handle/4` when it sees its worker `:failed`.
  Any other stop category returns `:not_auth` and the Driver keeps today's
  behaviour exactly. For an auth death, in this order:

    1. **Reclaim the debris.** A worker that never produced a commit leaves a
       worktree and a branch that are nothing but clutter. Both are removed —
       only when no other worker for the task is live, the worktree has no
       uncommitted changes, and the branch has no commits beyond
       `origin/<target>`. Anything else is kept exactly as it was. This runs
       *before* the reopen, so a re-dispatch can never race it for the same
       directory.
    2. **Return the task to Ready.** The `:failed` worker process is stopped
       (its `worker_runs` row stays `:failed`; the board files a card with a
       registered worker under Waiting, not Ready) and the task goes back to
       `:open`. Skipped — today's behaviour — for a review-only engagement, a
       resume / fix-round worker (the resume context would be lost to a fresh
       dispatch), a task no longer `:in_progress`, and a task that has already
       died on auth `AuthHold.max_task_reopens/0` times. That last bound is
       per task and independent of the hold, so no pattern of recoveries can
       cycle one task forever.

  The escalation `fail_stopped/2` sent is unchanged: the first death is still
  reported.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run

  @type outcome :: :not_auth | {:auth, %{debris: atom(), reopened: atom()}}

  @doc """
  Handle a `:failed` worker. `blocking` is the Driver's list of other live
  workers on this task (which forbid removing the worktree).
  """
  @spec handle(String.t(), pid(), map(), [String.t()]) :: outcome()
  def handle(task_id, worker_pid, worker_state, blocking)
      when is_binary(task_id) and is_map(worker_state) do
    if auth_death?(worker_state) do
      meta = Map.get(worker_state, :meta) || %{}
      debris = reclaim_debris(task_id, meta, blocking)
      reopened = maybe_reopen(task_id, worker_pid, meta)

      Logger.warning(
        "AuthDeath: task=#{task_id} worker died on auth — debris=#{debris} reopened=#{reopened}"
      )

      {:auth, %{debris: debris, reopened: reopened}}
    else
      :not_auth
    end
  end

  @doc "Did this worker stop with the `:auth_expired` category?"
  @spec auth_death?(map()) :: boolean()
  def auth_death?(%{meta: %{stop_reason: %{category: category}}}),
    do: category in [:auth_expired, "auth_expired"]

  def auth_death?(_), do: false

  # ---- 1. debris -----------------------------------------------------------

  defp reclaim_debris(task_id, meta, blocking) do
    with {:ok, path, repo_path, branch, base} <- worktree_facts(meta),
         :ok <- no_live_workers(blocking),
         :ok <- remove_worktree(path, base) do
      case Worktree.delete_branch(repo_path, branch, base) do
        :ok ->
          :reclaimed

        {:error, :has_commits} ->
          :has_commits

        {:error, reason} ->
          Logger.warning(
            "AuthDeath: task=#{task_id} could not delete branch #{branch}: #{inspect(reason)}"
          )

          :branch_delete_failed
      end
    else
      {:skip, why} -> why
    end
  end

  defp worktree_facts(meta) do
    with path when is_binary(path) <- Map.get(meta, :worktree_path),
         repo_path when is_binary(repo_path) <- Map.get(meta, :repo_path),
         branch when is_binary(branch) <- Map.get(meta, :branch),
         target when is_binary(target) <- Map.get(meta, :target_branch) do
      {:ok, path, repo_path, branch, "origin/" <> target}
    else
      _ -> {:skip, :no_worktree}
    end
  end

  defp no_live_workers([]), do: :ok
  defp no_live_workers(_blocking), do: {:skip, :live_workers}

  # Already gone is fine — the branch may still be there to reclaim.
  defp remove_worktree(path, base) do
    cond do
      not File.dir?(path) ->
        :ok

      Worktree.has_uncommitted?(path) != {:ok, false} ->
        {:skip, :dirty}

      Worktree.has_commits_ahead?(path, base) != {:ok, false} ->
        {:skip, :has_commits}

      true ->
        case Worktree.cleanup(path) do
          :ok -> :ok
          {:error, _} -> {:skip, :worktree_remove_failed}
        end
    end
  end

  # ---- 2. reopen -----------------------------------------------------------

  defp maybe_reopen(task_id, worker_pid, meta) do
    cond do
      truthy(meta, :review_only) ->
        :review_only

      truthy(meta, :resume) ->
        :resume

      true ->
        reopen(task_id, worker_pid)
    end
  end

  defp reopen(task_id, worker_pid) do
    with {:ok, %Issue{status: :in_progress} = task} <- Ash.get(Issue, task_id),
         :ok <- under_reopen_cap(task_id) do
      stop_failed_worker(worker_pid)

      case Ash.update(task, %{status: :open}) do
        {:ok, _} ->
          :reopened

        {:error, e} ->
          Logger.warning("AuthDeath: task=#{task_id} reopen failed: #{inspect(e)}")
          :reopen_failed
      end
    else
      {:ok, %Issue{}} -> :not_in_progress
      {:cap, n} -> cap_outcome(n, task_id)
      _ -> :task_not_found
    end
  rescue
    e ->
      Logger.warning("AuthDeath: task=#{task_id} reopen raised: #{Exception.message(e)}")
      :reopen_failed
  end

  defp cap_outcome(n, task_id) do
    Logger.warning(
      "AuthDeath: task=#{task_id} has died on auth #{n} time(s) " <>
        "(max_task_reopens #{AuthHold.max_task_reopens()}); leaving it :in_progress"
    )

    :reopen_cap
  end

  defp under_reopen_cap(task_id) do
    n =
      Run
      |> Ash.Query.filter(task_id == ^task_id and stop_category == "auth_expired")
      |> Ash.count!()

    if n < AuthHold.max_task_reopens(), do: :ok, else: {:cap, n}
  end

  # The board files a card with any registered author worker under Waiting,
  # so the failed worker has to go for the card to be Ready. Its run row is
  # already stamped `:failed`, and `terminate/2` does not rewrite a terminal
  # row. The worker is `restart: :temporary`, so this is not a restart.
  defp stop_failed_worker(pid) when is_pid(pid) do
    _ = Worker.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_failed_worker(_), do: :ok

  defp truthy(meta, key), do: Map.get(meta, key) == true or Map.get(meta, to_string(key)) == true
end
