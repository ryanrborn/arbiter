defmodule Arbiter.Tasks.Workspace.Changes.StartDispatchQueue do
  @moduledoc """
  After-action hook that starts a `Arbiter.Workflows.DispatchQueue` for a newly
  created workspace (bd-7cd38f), so its `quota:<ws>` subscription is live and it
  can drain-on-headroom even before the first held dispatch. Gated by
  `Arbiter.Workflows.DispatchQueueSupervisor.auto_start?/0` so tests opt out.

  Best-effort: a failure to start is logged but does not fail the workspace
  create — the boot enumeration on next app start, or the lazy `ensure_started/1`
  on the first hold, would catch it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.DispatchQueueSupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if DispatchQueueSupervisor.auto_start?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        case DispatchQueueSupervisor.start_dispatch_queue(workspace.id) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          :ignore ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StartDispatchQueue: failed to start dispatch queue for workspace " <>
                "#{workspace.id}: #{inspect(reason)}"
            )
        end

        {:ok, workspace}
      end)
    else
      changeset
    end
  end
end
