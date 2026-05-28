defmodule Arbiter.Beads.Issue.Changes.StopPolecat do
  @moduledoc """
  After-action hook for the `:close` action: if a polecat GenServer is
  registered for this bead, stop it cleanly.

  Best-effort: when no polecat is running, silently skip. Any failure to
  stop the polecat is logged but never propagated — the `:close` action
  must succeed even if teardown does not.

  Pairs with `Arbiter.Beads.Issue.Changes.CleanupWorktree`, which handles
  the on-disk side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Polecat

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      stop(issue.id)
      {:ok, issue}
    end)
  end

  defp stop(bead_id) do
    case Polecat.whereis(bead_id) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        try do
          Polecat.stop(pid)
        rescue
          e ->
            Logger.warning(
              "StopPolecat: error stopping polecat for bead=#{bead_id}: #{Exception.message(e)}"
            )
        catch
          :exit, reason ->
            Logger.warning(
              "StopPolecat: exit stopping polecat for bead=#{bead_id}: #{inspect(reason)}"
            )
        end

        :ok
    end
  end
end
