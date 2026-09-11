defmodule Arbiter.Tasks.Issue.Changes.DropDispatchHold do
  @moduledoc """
  After-action hook for the `:close` action: drop any `DispatchQueue`-held
  dispatch intent for this task (bd-atjyzu), so a task that closes while its
  dispatch is held for quota doesn't sit there until the next drain
  re-discovers (and would otherwise re-queue) it.

  Best-effort: the queue may not be running for this workspace at all — the
  common case, since most tasks never hold — and that is not a failure.
  """

  use Ash.Resource.Change

  alias Arbiter.Workflows.DispatchQueue

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      DispatchQueue.drop(issue.workspace_id, issue.id)
      {:ok, issue}
    end)
  end
end
