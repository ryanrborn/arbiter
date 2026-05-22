defmodule Arbiter.Beads.Issue.Changes.GuardStatus do
  @moduledoc """
  Enforces the Issue status FSM:

      :open ⇄ :in_progress
       │          │
       └────►─────┴────► :closed
                          │
                          └ reopen → :open

  Rules by action:

  * `:update` — caller may change status open ⇄ in_progress only. Transitioning
    to or from `:closed` requires the `:close` / `:reopen` actions explicitly.
  * `:close` — current status must be `:open` or `:in_progress`. Cannot close an
    already-closed issue (silent no-op would mask bugs).
  * `:reopen` — current status must be `:closed`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, opts, _context) do
    action = Keyword.fetch!(opts, :action)

    Changeset.before_action(changeset, fn cs ->
      current = cs.data.status
      validate(cs, action, current)
    end)
  end

  defp validate(cs, :update, current) do
    new_status = Changeset.get_attribute(cs, :status)

    cond do
      # No status change → fine
      new_status == current ->
        cs

      # Cannot move into :closed via :update — use :close action
      new_status == :closed ->
        Changeset.add_error(cs,
          field: :status,
          message: "Use the :close action to close an issue, not :update."
        )

      # Cannot move out of :closed via :update — use :reopen action
      current == :closed ->
        Changeset.add_error(cs,
          field: :status,
          message: "Issue is closed. Use the :reopen action to re-open it."
        )

      # open ⇄ in_progress allowed
      new_status in [:open, :in_progress] and current in [:open, :in_progress] ->
        cs

      true ->
        Changeset.add_error(cs,
          field: :status,
          message: "Invalid status transition #{current} → #{new_status}"
        )
    end
  end

  defp validate(cs, :close, current) do
    case current do
      :closed ->
        Changeset.add_error(cs,
          field: :status,
          message: "Issue is already closed."
        )

      status when status in [:open, :in_progress] ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message: "Cannot close issue with status #{current}"
        )
    end
  end

  defp validate(cs, :reopen, current) do
    case current do
      :closed ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message: "Cannot reopen issue with status #{current} (must be :closed)"
        )
    end
  end
end
