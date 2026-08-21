defmodule Arbiter.Repo.Migrations.AddSourceToWorkerRunSteps do
  @moduledoc """
  Adds `worker_run_steps.source` (bd-apwfmy, Phase 2).

  Distinguishes a row the live `Arbiter.Worker.ClaudeSession` emit path wrote
  as the run happened ("live") from one `Arbiter.Workers.StepBackfill`
  reconstructed afterwards from the on-disk Claude session JSONL
  ("backfill"). They are not equivalent evidence: a backfilled row's
  `duration_ms` comes from line timestamps rather than a monotonic clock, its
  summaries were redacted against the secret values known *now* rather than
  the ones the run actually held, and it exists only if the session file
  survived. Any analysis that cares about those differences needs to be able
  to see them, so the provenance is a column rather than a guess.

  Existing rows all predate the backfill, so they are "live" by construction —
  hence the backfill of the column itself in `up/0`.

  Hand-written: this repo's `priv/resource_snapshots/` are stale enough that
  `mix ash_sqlite.generate_migrations` emits a large destructive diff.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_run_steps) do
      add(:source, :text)
    end

    execute("UPDATE worker_run_steps SET source = 'live' WHERE source IS NULL")

    create index(:worker_run_steps, [:source])
  end

  def down do
    drop_if_exists index(:worker_run_steps, [:source])

    alter table(:worker_run_steps) do
      remove(:source)
    end
  end
end
