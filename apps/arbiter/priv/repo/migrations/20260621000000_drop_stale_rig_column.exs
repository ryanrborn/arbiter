defmodule Arbiter.Repo.Migrations.DropStaleRigColumn do
  @moduledoc """
  Drops the stale `rig` column from `worker_runs` and adds the missing `repo`
  column (bd-17dl83).

  The `rename_rig_to_repo` migration attempted to rename `rig` to `repo`, but on
  existing databases, the rename failed and left the NOT NULL `rig` column in
  place without creating `repo`. The Elixir resource (`Arbiter.Workers.Run`)
  only writes to `repo`, so every INSERT failed with "NOT NULL constraint
  failed: worker_runs.rig".

  PRAGMA table_info confirmed:
    - `worker_runs` has `rig TEXT NOT NULL` (stale, never written to)
    - `worker_runs` has NO `repo` column (the resource's target)
    - `usage_events` has `repo TEXT` (nullable, no `rig`)

  This migration:
    1. Drops the stale `rig` column
    2. Adds the missing `repo` column (nullable to match fresh schema)
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE worker_runs DROP COLUMN rig")
    execute("ALTER TABLE worker_runs ADD COLUMN repo TEXT")
  end

  def down do
    execute("ALTER TABLE worker_runs DROP COLUMN repo")
    execute("ALTER TABLE worker_runs ADD COLUMN rig TEXT NOT NULL DEFAULT ''")
  end
end
