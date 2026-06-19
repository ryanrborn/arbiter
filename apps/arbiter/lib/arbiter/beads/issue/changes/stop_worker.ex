defmodule Arbiter.Beads.Issue.Changes.StopWorker do
  @moduledoc """
  After-action hook for the `:close` action: if a worker GenServer is
  registered for this bead, stop it cleanly.

  Best-effort: when no worker is running, silently skip. Any failure to
  stop the worker is logged but never propagated — the `:close` action
  must succeed even if teardown does not.

  Pairs with `Arbiter.Beads.Issue.Changes.CleanupWorktree`, which handles
  the on-disk side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Worker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      stop(issue.id)
      {:ok, issue}
    end)
  end

  defp stop(bead_id) do
    case Worker.whereis(bead_id) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        try do
          Worker.stop(pid)
        rescue
          e ->
            Logger.warning(
              "StopWorker: error stopping worker for bead=#{bead_id}: #{Exception.message(e)}"
            )
        catch
          :exit, reason ->
            Logger.warning(
              "StopWorker: exit stopping worker for bead=#{bead_id}: #{inspect(reason)}"
            )
        end

        :ok
    end
  end
end
