defmodule Arbiter.Repo.Migrations.RenameRigToRepo do
  @moduledoc """
  Renames the `rig` column to `repo` in worker_runs and usage_events.

  Guards are in place so this migration is idempotent on fresh installs where
  the initial migration already creates `repo` columns.
  """

  use Ecto.Migration

  def up do
    maybe_rename_column("worker_runs", "rig", "repo")
    maybe_rename_column("usage_events", "rig", "repo")
  end

  def down do
    rename table(:worker_runs), :repo, to: :rig
    rename table(:usage_events), :repo, to: :rig
  end

  defp maybe_rename_column(tbl, old_col, new_col) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{tbl})")
    col_names = Enum.map(rows, fn row -> Enum.at(row, 1) end)

    if old_col in col_names do
      execute("ALTER TABLE #{tbl} RENAME COLUMN #{old_col} TO #{new_col}")
    end
  end
end
