defmodule Arbiter.Tasks.Issue.Changes.RecordCloseIntent do
  @moduledoc """
  Persist what a close *meant* for the linked tracker issue (bd-bsco7f).

  `close_upstream` is an argument on `:close`, so it evaporates when the action
  returns. Anything that later asks "was this close supposed to close the
  ticket?" — `Tasks.Claim`'s drift check, chiefly — had no answer and inferred
  one from `pr_ref`'s presence. That proxy misses the manual-close path
  entirely: a `bug` fixed by hand or as a drive-by ships no PR through the
  merger, so a failed upstream propagation on it looked exactly like a
  findings-only investigation whose ticket is *supposed* to stay open.

  This change writes the answer down, in the same shape
  `Arbiter.Tasks.Issue.Changes.SyncTracker` uses to decide whether to push:

    * `review_only` — records `false` whichever action asked, and it is checked
      first. SyncTracker refuses to transition a tracker issue a review-only
      task merely borrowed (bd-6xaaam) — both on `:close` (`maybe_sync/4`) and
      on the forced `:sync_upstream_close` (`maybe_force_sync/1`) — so recording
      `true` for one would claim an upstream close that provably never happened
      and manufacture drift on someone else's ticket.
    * `:sync_upstream_close` (`forced: true`) — records `true`. That action's
      whole purpose is pushing a close upstream for a task already closed
      locally, so there is no intent to infer.
    * `:close` — records the `close_upstream` argument.

  Nothing writes `false`-by-omission: a `nil` column means the close predates
  this record, and the drift check falls back to the `pr_ref` proxy for it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :close_upstream_expected,
      expected?(changeset, opts)
    )
  end

  defp expected?(changeset, opts) do
    cond do
      changeset.data.review_only == true -> false
      Keyword.get(opts, :forced, false) -> true
      true -> Ash.Changeset.get_argument(changeset, :close_upstream) == true
    end
  end
end
