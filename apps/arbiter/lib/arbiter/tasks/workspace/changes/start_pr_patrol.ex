defmodule Arbiter.Tasks.Workspace.Changes.StartPRPatrol do
  @moduledoc """
  After-action hook that starts a PRPatrol process for a newly created workspace
  if it is configured for GitHub merges. Gated by
  `Arbiter.Workflows.PRPatrolSupervisor.auto_start?/0` so tests can opt out.

  Best-effort: a failure to start the patrol is logged but does not fail the
  workspace create — the boot enumeration on next app start would catch it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.PRPatrolSupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if PRPatrolSupervisor.auto_start?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        case PRPatrolSupervisor.start_patrol(workspace) do
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
              "StartPRPatrol: failed to start patrol for workspace #{workspace.id}: " <>
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
