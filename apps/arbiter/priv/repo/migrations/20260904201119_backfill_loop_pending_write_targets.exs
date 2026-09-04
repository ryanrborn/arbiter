defmodule Arbiter.Repo.Migrations.BackfillLoopPendingWriteTargets do
  @moduledoc """
  bd-5w8h0r: re-home the finding-category proposals written before the
  category → skill attribution table existed.

  `target` is a fingerprint input, so naming a target for a category changes
  the identity of every proposal in it. Without this the live pre-table rows
  would strand at an unreachable fingerprint while the next pass opened empty
  rows beside them. See `Arbiter.Loop.PendingWriteTargetBackfill` for the rule
  and for what it deliberately does not touch.
  """

  use Ecto.Migration

  def up do
    %{
      examined: examined,
      superseded: superseded,
      inserted: inserted,
      merged: merged,
      unresolved: unresolved
    } = Arbiter.Loop.PendingWriteTargetBackfill.run()

    IO.puts(
      "[backfill_loop_pending_write_targets] examined #{examined} live target-less " <>
        "finding row(s); superseded #{superseded} (#{inserted} re-homed onto a new " <>
        "fingerprint, #{merged} merged into a successor a later pass had already " <>
        "opened); #{unresolved} left live with no attribution row for their category."
    )
  end

  # Irreversible by design: the successors carry unioned evidence, so there is
  # no faithful way to split them back apart. Rolling the attribution table
  # back means writing a new forward backfill, the same way changing it later
  # will (see `Arbiter.Loop.FindingBuckets` — the table is fingerprint
  # load-bearing).
  def down do
    :ok
  end
end
