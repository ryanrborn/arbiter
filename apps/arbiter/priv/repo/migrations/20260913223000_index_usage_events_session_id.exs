defmodule Arbiter.Repo.Migrations.IndexUsageEventsSessionId do
  @moduledoc """
  Index `usage_events.session_id` (bd-be804c, RFC phase 6 §7.4 item 3).

  Coordinator-session metering writes one row per session per ingest cycle,
  keyed only by `session_id` (`task_id` is nil for `source: :coordinator_session`).
  Two readers make that column hot:

    * `Arbiter.Sessions.UsageIngest` looks up the rows already billed for a
      session on **every** cycle, for **every** file it sweeps — the lookup that
      makes the ingest idempotent. Without an index that is a full scan of the
      ledger per file per cycle.
    * `arb usage --by session` (RFC phase 7) groups on it.

  A plain single-column index; the table is small and read eagerly, so nothing
  wider is justified yet.
  """

  use Ecto.Migration

  def up do
    create index(:usage_events, [:session_id])
  end

  def down do
    drop_if_exists index(:usage_events, [:session_id], name: "usage_events_session_id_index")
  end
end
