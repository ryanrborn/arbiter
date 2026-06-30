defmodule Arbiter.Tasks.Workspace.Changes.StartMergedPRFinalizer do
  @moduledoc """
  After-action hook that starts a MergedPRFinalizer process for a newly created
  workspace if it is configured for GitHub merges. Gated by
  `Arbiter.Workflows.MergedPRFinalizerSupervisor.auto_start?/0` so tests can
  opt out.

  Best-effort: a failure to start the finalizer is logged but does not fail the
  workspace create — the boot enumeration on next app start catches it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.MergedPRFinalizerSupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if MergedPRFinalizerSupervisor.auto_start?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        case MergedPRFinalizerSupervisor.start_finalizer(workspace) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          :skip ->
            :ok

          :ignore ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StartMergedPRFinalizer: failed to start finalizer for workspace #{workspace.id}: " <>
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
