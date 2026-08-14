defmodule Arbiter.Tasks.Issue.Changes.StopWorker do
  @moduledoc """
  After-action hook for the `:close` action: stop every worker GenServer
  registered under this task, including synthetic sub-worker keys
  (`<task_id>:fixpass`, `<task_id>:conflict`, `<task_id>#review`, etc).

  Best-effort: when no worker is running, silently skip. Any failure to
  stop a worker is logged but never propagated — the `:close` action must
  succeed even if teardown does not.

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

  # A worker belongs to `task_id` when its registry key IS `task_id`, or is
  # `task_id` immediately followed by a synthetic-key separator (`:fixpass`,
  # `:conflict`, `#review`, `#r<N>`, ...). Requiring the separator right after
  # the prefix (rather than a bare `String.starts_with?/2` on `task_id`
  # alone) keeps an unrelated task whose id happens to be a string-prefix of
  # another (e.g. "bd-1" vs "bd-12:fixpass") from matching.
  defp owned_by?(registry_key, task_id) do
    registry_key == task_id or
      String.starts_with?(registry_key, task_id <> ":") or
      String.starts_with?(registry_key, task_id <> "#")
  end

  # Enumerates via the Registry (not `Worker.list_children/0`, which probes
  # each pid with `GenServer.call(pid, :snapshot, 500)` and silently drops
  # any worker that doesn't answer within the timeout — e.g. one mid-merge
  # in `handle_call({:open_mr, ...})`). Registry enumeration needs no call
  # to the worker process itself, so a busy sub-worker is still swept.
  defp stop_all(task_id) do
    WorkerRegistry.all()
    |> Enum.filter(fn {registry_key, _pid} -> owned_by?(registry_key, task_id) end)
    |> Enum.each(fn {registry_key, pid} -> stop(pid, registry_key) end)
  rescue
    e ->
      Logger.warning("StopWorker: error enumerating workers for #{task_id}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("StopWorker: exit enumerating workers for #{task_id}: #{inspect(reason)}")
  end

  defp stop(pid, registry_key) do
    Worker.stop(pid)
  rescue
    e ->
      Logger.warning(
        "StopWorker: error stopping worker key=#{registry_key}: #{Exception.message(e)}"
      )
  catch
    :exit, reason ->
      Logger.warning(
        "StopWorker: exit stopping worker key=#{registry_key}: #{inspect(reason)}"
      )
  end
end
