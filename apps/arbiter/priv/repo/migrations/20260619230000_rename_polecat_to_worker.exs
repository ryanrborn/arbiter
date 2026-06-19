defmodule Arbiter.Repo.Migrations.RenamePolecat do
  @moduledoc """
  Renames the `polecat_runs` table to `worker_runs` and the `polecat_run_id`
  column in `usage_events` to `worker_run_id`.

  Guards are in place so this migration is idempotent on fresh installs where
  the initial migration already creates `worker_runs` / `worker_run_id`.
  """

  use Ecto.Migration

  def up do
    if table_exists?("polecat_runs") do
      execute("ALTER TABLE polecat_runs RENAME TO worker_runs")
    end

    %{rows: rows} = repo().query!("PRAGMA table_info(usage_events)")
    col_names = Enum.map(rows, fn row -> Enum.at(row, 1) end)

    if "polecat_run_id" in col_names do
      execute("ALTER TABLE usage_events RENAME COLUMN polecat_run_id TO worker_run_id")
    end
  end

  defp table_exists?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [name]
      )

    rows != []
  end

  def down do
    rename table(:worker_runs), to: table(:polecat_runs)
    rename table(:usage_events), :worker_run_id, to: :polecat_run_id
  end
end
