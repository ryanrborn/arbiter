defmodule Arbiter.Beads.Workspace.Changes.StartRefinery do
  @moduledoc """
  After-action hook that starts a Refinery (Crucible) process for a newly
  created workspace. Gated by `Arbiter.Workflows.RefinerySupervisor.auto_start?/0`
  so tests can opt out.

  Best-effort: a failure to start the Refinery is logged but does not fail the
  workspace create — the boot enumeration on next app start would catch it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.RefinerySupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if RefinerySupervisor.auto_start?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        case RefinerySupervisor.start_refinery(workspace.id) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StartRefinery: failed to start refinery for workspace #{workspace.id}: " <>
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
