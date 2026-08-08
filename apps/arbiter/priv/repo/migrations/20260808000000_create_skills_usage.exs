defmodule Arbiter.Repo.Migrations.CreateSkillsUsage do
  use Ecto.Migration

  def change do
    create table(:skills_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :skill_id, :binary_id, null: false
      add :materialize_count, :integer, default: 0, null: false
      add :invoke_count, :integer, default: 0, null: false
      add :patch_count, :integer, default: 0, null: false
      add :last_materialized_at, :utc_datetime
      add :last_invoked_at, :utc_datetime
      add :last_patched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:skills_usage, [:skill_id])
  end
end
