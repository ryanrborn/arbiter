defmodule Arbiter.Repo.Migrations.AddClearedAtToMessages do
  @moduledoc """
  Adds the mailbox `cleared_at` state to `messages`, an index over the new
  outstanding query, and backfills existing rows.

  bd-9kmq04 — split "seen" (`read_at`) from "addressed" (`cleared_at`) so that
  clearing a mailbox message becomes a soft state transition instead of a
  destroy. This is a hand-written, messages-only migration: `mix ash.codegen`
  folds in unrelated snapshot drift from other resources, so only the messages
  DDL belongs here.

  Backfill decision (do not re-litigate): every pre-existing row with
  `read_at NOT NULL` is treated as already-addressed (`cleared_at = read_at`).
  Under the old semantics reading *was* the act of consumption — `arb inbox`
  dropped the unread count to zero and the operator treated those as handled —
  so backfilling them as cleared preserves that expectation. Treating every
  historical read row as newly "outstanding" would instead dump a flood of
  stale items onto the dashboard on deploy.
  """

  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:cleared_at, :utc_datetime_usec)
    end

    create(index(:messages, ["workspace_id", "to_ref", "cleared_at"]))

    # Backfill: historically-read rows are considered already addressed. No
    # historical row becomes "outstanding" (read-but-uncleared) on deploy.
    execute(
      "UPDATE messages SET cleared_at = read_at WHERE read_at IS NOT NULL",
      "UPDATE messages SET cleared_at = NULL"
    )
  end

  def down do
    drop_if_exists(
      index(:messages, ["workspace_id", "to_ref", "cleared_at"],
        name: "messages_workspace_id_to_ref_cleared_at_index"
      )
    )

    alter table(:messages) do
      remove(:cleared_at)
    end
  end
end
