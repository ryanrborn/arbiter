defmodule Arbiter.Repo.Migrations.RenameBeadToTask do
  @moduledoc """
  Renames bead_id / bead_title columns to task_id / task_title across:
    - workflow_machine_states.bead_id  -> task_id
    - usage_events.bead_id            -> task_id  (index rebuilt)
    - worker_runs.bead_id             -> task_id
    - worker_runs.bead_title          -> task_title

  Guards are in place so this migration is idempotent on fresh installs
  where the initial migration already creates task_* columns.
  """

  use Ecto.Migration

  def up do
    rename_col("workflow_machine_states", "bead_id", "task_id")
    rename_col("usage_events", "bead_id", "task_id")
    rename_col("worker_runs", "bead_id", "task_id")
    rename_col("worker_runs", "bead_title", "task_title")

    # Rebuild the index on usage_events after column rename.
    drop_if_exists(
      index(:usage_events, ["bead_id", "occurred_at"],
        name: "usage_events_bead_id_occurred_at_index"
      )
    )

    create_if_not_exists(index(:usage_events, [:task_id, :occurred_at]))
  end

  def down do
    rename_col("usage_events", "task_id", "bead_id")
    rename_col("workflow_machine_states", "task_id", "bead_id")
    rename_col("worker_runs", "task_id", "bead_id")
    rename_col("worker_runs", "task_title", "bead_title")

    drop_if_exists(index(:usage_events, [:task_id, :occurred_at]))
    create_if_not_exists(index(:usage_events, [:bead_id, :occurred_at]))
  end

  defp rename_col(table, from, to) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table})")
    col_names = Enum.map(rows, fn row -> Enum.at(row, 1) end)

    if from in col_names do
      execute("ALTER TABLE #{table} RENAME COLUMN #{from} TO #{to}")
    end
  end
end
