defmodule Arbiter.Tasks.Issue.Changes.StopWorker do
  @moduledoc """
  After-action hook for the `:close` action: stop every worker GenServer
  registered under this task, including synthetic sub-worker keys
  (`<task_id>:fixpass`, `<task_id>:conflict`, `<task_id>#review`, etc).

  Best-effort: when no worker is running, silently skip. Any failure to
  stop a worker is logged but never propagated — the `:close` action must
  succeed even if teardown does not.

  Stopping a worker also kills its agent's OS process tree, synchronously,
  inside `Worker.terminate/2` (bd-bmmj4w) — so when this hook's stop returns
  `:ok` the agent is provably no longer running in the task's worktree, which
  is the precondition `CleanupWorktree` relies on before removing it.

  Pairs with `Arbiter.Tasks.Issue.Changes.CleanupWorktree`, which handles
  the on-disk side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Worker
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      stop_all(issue.id)
      {:ok, issue}
    end)
  end

  # Enumerates via the Registry (not `Worker.list_children/0`, which probes
  # each pid with `GenServer.call(pid, :snapshot, 500)` and silently drops
  # any worker that doesn't answer within the timeout — e.g. one mid-merge
  # in `handle_call({:open_mr, ...})`). Registry enumeration needs no call
  # to the worker process itself, so a busy sub-worker is still swept.
  # `all_for/1` owns the synthetic-key matching rule (`:fixpass`, `#review`,
  # ...) shared with CleanupWorktree's liveness re-check.
  defp stop_all(task_id) do
    WorkerRegistry.all_for(task_id)
    |> Enum.each(fn {registry_key, pid} -> stop(pid, registry_key) end)
  rescue
    e ->
      Logger.warning(
        "StopWorker: error enumerating workers for #{task_id}: #{Exception.message(e)}"
      )
  catch
    :exit, reason ->
      Logger.warning("StopWorker: exit enumerating workers for #{task_id}: #{inspect(reason)}")
  end

  # Bounded stop, where `Worker.stop/2` defaults to GenServer.stop's
  # `:infinity`: this hook runs inside the :close action's hook pipeline, so a
  # worker wedged in a slow terminate must not hang every close of its task.
  # On timeout the worker is left still terminating — which is exactly why
  # CleanupWorktree independently re-checks liveness before removing the
  # worktree that worker may still be running in (bd-bmmj4w), rather than
  # assuming this sweep fully drained everything. Goes through `Worker.stop/3`
  # rather than `GenServer.stop/3` so any teardown the Worker module adds to
  # its own stop API applies here too.
  defp stop(pid, registry_key) do
    Worker.stop(pid, :normal, stop_timeout_ms())
  rescue
    e ->
      Logger.warning(
        "StopWorker: error stopping worker key=#{registry_key}: #{Exception.message(e)}"
      )
  catch
    :exit, reason ->
      Logger.warning("StopWorker: exit stopping worker key=#{registry_key}: #{inspect(reason)}")
  end

  defp stop_timeout_ms do
    Application.get_env(:arbiter, :stop_worker_timeout_ms, 15_000)
  end
end
