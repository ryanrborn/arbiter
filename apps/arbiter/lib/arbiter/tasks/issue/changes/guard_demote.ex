defmodule Arbiter.Tasks.Issue.Changes.GuardDemote do
  @moduledoc """
  Enforces preconditions for the `:return_to_backlog` action.

  A task can only be demoted (refined: true → false) if:
  1. It has no live worker (task is not currently being executed)
  2. Its status is :open (undispatch, or not yet started)

  Demoting a task that is :in_progress, :awaiting_verification, or :closed
  is refused because those states represent active or completed work —
  moving them back to Backlog would orphan the worker or undo completed work.

  Idempotent by construction — demoting an already-backlog task is a no-op.
  """

  use Ash.Resource.Change

  require Logger

  alias Ash.Changeset
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      validate(cs)
    end)
  end

  defp validate(cs) do
    task_id = cs.data.id
    current_status = cs.data.status
    current_refined = cs.data.refined

    cond do
      # If already false, it's a no-op
      current_refined == false ->
        cs

      # Refuse if status is :in_progress (task is actively being worked on)
      current_status == :in_progress ->
        Changeset.add_error(cs,
          field: :refined,
          message:
            "Cannot demote a task that is in progress. Stop the worker first " <>
              "or wait for it to complete."
        )

      # Refuse if status is :awaiting_verification
      current_status == :awaiting_verification ->
        Changeset.add_error(cs,
          field: :refined,
          message:
            "Cannot demote a task that is awaiting verification. " <>
              "Record a verification outcome first."
        )

      # Refuse if status is :closed
      current_status == :closed ->
        Changeset.add_error(cs,
          field: :refined,
          message: "Cannot demote a closed task. Only undispatched or open tasks can be demoted."
        )

      # Check for live workers
      has_live_workers?(task_id) ->
        Changeset.add_error(cs,
          field: :refined,
          message:
            "Cannot demote a task with a live worker. Stop the worker first " <>
              "(`arb worker stop #{task_id}`) before demoting."
        )

      # All checks passed
      true ->
        cs
    end
  end

  defp has_live_workers?(task_id) do
    WorkerRegistry.live_for(task_id) |> Enum.any?()
  rescue
    _ -> false
  end
end
