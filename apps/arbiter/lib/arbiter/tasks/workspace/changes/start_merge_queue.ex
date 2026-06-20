defmodule Arbiter.Tasks.Workspace.Changes.StartMergeQueue do
  @moduledoc """
  After-action hook that starts a MergeQueue (merge queue) process for a newly
  created workspace. Gated by `Arbiter.Workflows.MergeQueueSupervisor.auto_start?/0`
  so tests can opt out.

  Best-effort: a failure to start the MergeQueue is logged but does not fail the
  workspace create — the boot enumeration on next app start would catch it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.MergeQueueSupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if MergeQueueSupervisor.auto_start?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        case MergeQueueSupervisor.start_merge_queue(workspace.id) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          # `DynamicSupervisor.on_start_child/0` admits `:ignore`. Today
          # `MergeQueue.init/1` doesn't return it, but a no-op match keeps the
          # spec exhaustive.
          :ignore ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StartMergeQueue: failed to start merge_queue for workspace #{workspace.id}: " <>
                inspect(reason)
            )
        end

        {:ok, workspace}
      end)
    else
      changeset
    end
  end
end
