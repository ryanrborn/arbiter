defmodule Arbiter.Repo.Migrations.RedateCoordinatorSessionUsage do
  @moduledoc """
  Drop the coordinator-session rows written by the first ingest deploy, so the
  sweeper re-derives them at their real dates (bd-be804c follow-up).

  The first deploy of `Arbiter.Sessions.UsageIngest` stamped every row with
  `occurred_at: DateTime.utc_now()`. On a host whose oldest transcript goes
  back weeks, that filed *all* of it — 16 rows, $739.08 on the dogfood host — on
  the single day the sweeper first ran, which is exactly the column
  `arb usage --by day` and `--since 1d` read. Those rows are not repairable in place: one row conflates
  many days of spend, and only the transcripts know how it splits.

  They don't need repairing, because they are **derived data**. The ingest's
  watermark is the ledger itself, so deleting a row doesn't lose the spend — it
  makes the next sweep re-derive it from the session JSONL, which is the source
  of truth, now split per UTC day and priced even where the CLI wrote no
  `cost-state` record. One cycle (≤5 minutes) after this migration the same
  dollars are back, on the right days.

  ## Scope

  Only rows that the *old* writer produced. Every row the new writer creates
  carries a `"day"` key in its `raw` provenance map, so matching on its absence
  is precise, and re-running this migration after a sweep is a no-op rather
  than a second round of deletions.

  `down` is deliberately a no-op: the deleted rows are reconstructible from
  disk and were wrong; re-inserting them is neither possible nor desirable.
  """

  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM usage_events
     WHERE source = 'coordinator_session'
       AND (raw IS NULL OR raw NOT LIKE '%"day"%')
    """)
  end

  def down do
    # Irreversible by design — see the moduledoc. The coordinator-session
    # ledger re-derives itself from the transcripts on the next sweep.
    :ok
  end
end
