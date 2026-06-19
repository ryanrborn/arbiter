defmodule Arbiter.Repo.Migrations.RenameRigToRepo do
  @moduledoc """
  Renames the `rig` column to `repo` in polecat_runs and usage_events.
  """

  use Ecto.Migration

  def up do
    rename table(:polecat_runs), :rig, to: :repo
    rename table(:usage_events), :rig, to: :repo
  end

  def down do
    rename table(:polecat_runs), :repo, to: :rig
    rename table(:usage_events), :repo, to: :rig
  end
end
