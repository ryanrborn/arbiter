defmodule Arbiter.Repo.Migrations.AddWorkerTypeAndModelToWorkerRuns do
  @moduledoc """
  Adds two columns to `worker_runs` (bd-3fivfl):

    - `worker_type` — which kind of worker produced the run (`main` / `review` /
      `impl`), so a task's history records *who* worked it at each step.
      Backfilled to `main` for existing rows (they predate review/impl tracking).
    - `model` — the resolved agent model id for the run, nullable.

  Also creates a `(task_id, started_at)` index powering the per-task run
  history list (`GET /api/workers/history?task_id=…` / `arb worker runs`).

  Idempotent: each column is added only if it is not already present, so the
  migration is safe to re-run and on fresh installs.
  """

  use Ecto.Migration

  def up do
    add_col("worker_type", "TEXT NOT NULL DEFAULT 'main'")
    add_col("model", "TEXT")

    create_if_not_exists(index(:worker_runs, [:task_id, :started_at]))
  end

  def down do
    drop_if_exists(index(:worker_runs, [:task_id, :started_at]))

    drop_col("model")
    drop_col("worker_type")
  end

  defp add_col(name, type) do
    unless column_exists?(name) do
      execute("ALTER TABLE worker_runs ADD COLUMN #{name} #{type}")
    end
  end

  defp drop_col(name) do
    if column_exists?(name) do
      execute("ALTER TABLE worker_runs DROP COLUMN #{name}")
    end
  end

  defp column_exists?(name) do
    %{rows: rows} = repo().query!("PRAGMA table_info(worker_runs)")
    name in Enum.map(rows, fn row -> Enum.at(row, 1) end)
  end
end
