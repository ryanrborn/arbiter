defmodule Arbiter.Tasks.Issue.Changes.GuardStatus do
  @moduledoc """
  Enforces the Issue status FSM:

      :open ⇄ :in_progress
       │          │
       │          ├────► :awaiting_verification ─┬─► :closed
       │          │                              └─► reopen → :open
       └────►─────┴────► :closed
                          │
                          └ reopen → :open

  Rules by action:

  * `:update` — caller may change status open ⇄ in_progress only. Transitioning
    to or from `:closed` / `:awaiting_verification` requires the `:close` /
    `:reopen` / `:await_verification` actions explicitly.
  * `:await_verification` (bd-9so315) — current status must be `:open` or
    `:in_progress`. A closed task has nothing left to verify, and re-entering
    the state from itself would reset the clock the coordinator is watching.
  * `:record_verification` (bd-9so315) — current status must be
    `:awaiting_verification`; there is no verdict to record otherwise.
  * `:close` — current status must be `:open`, `:in_progress` or
    `:awaiting_verification`. Cannot close an already-closed issue (silent
    no-op would mask bugs).
  * `:reopen` — current status must be `:closed` or `:awaiting_verification`
    (a failed verification sends the task back for another attempt).
  * `:sync_upstream_close` — current status must already be `:closed`. Makes no
    local status/closed_at change; only pushes a close to the linked tracker
    for a task that closed without `close_upstream: true` at the time.
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

      # Cannot move into :awaiting_verification via :update — use
      # :await_verification, which stamps the clock and runs teardown.
      new_status == :awaiting_verification ->
        Changeset.add_error(cs,
          field: :status,
          message:
            "Use the :await_verification action to park an issue for post-merge " <>
              "verification, not :update."
        )

      # Cannot move out of :awaiting_verification via :update — the only exits
      # are a recorded verdict (:close / :reopen via Tasks.Verification).
      current == :awaiting_verification ->
        Changeset.add_error(cs,
          field: :status,
          message:
            "Issue is awaiting post-merge verification. Record a verdict " <>
              "(`arb issue verify`) instead of changing status via :update."
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

      status when status in [:open, :in_progress, :awaiting_verification] ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message: "Cannot close issue with status #{current}"
        )
    end
  end

  defp validate(cs, :sync_upstream_close, current) do
    case current do
      :closed ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message: "Cannot sync_upstream_close issue with status #{current} (must be :closed)"
        )
    end
  end

  defp validate(cs, :reopen, current) do
    case current do
      status when status in [:closed, :awaiting_verification] ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message:
            "Cannot reopen issue with status #{current} " <>
              "(must be :closed or :awaiting_verification)"
        )
    end
  end

  defp validate(cs, :await_verification, current) do
    case current do
      status when status in [:open, :in_progress] ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message:
            "Cannot park issue for verification with status #{current} " <>
              "(must be :open or :in_progress)"
        )
    end
  end

  defp validate(cs, :record_verification, current) do
    case current do
      :awaiting_verification ->
        cs

      _ ->
        Changeset.add_error(cs,
          field: :status,
          message:
            "Cannot record a verification verdict for an issue with status " <>
              "#{current} (must be :awaiting_verification)"
        )
    end
  end
end
