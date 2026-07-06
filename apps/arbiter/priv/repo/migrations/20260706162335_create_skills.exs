defmodule Arbiter.Repo.Migrations.CreateSkills do
  @moduledoc """
  Creates `skills` (bd-cj6i08): the system-wide registry of user-authored
  worker skills (epic bd-xfc55c). Each row is a reusable markdown instruction
  module (`Arbiter.Skills.Skill`) that arbiter materializes into a worker's
  worktree at `.claude/skills/<name>/SKILL.md`.

  System-wide, NOT workspace-scoped — one definition is shared across the whole
  arbiter system, so there is no `workspace_id` column. `name` is unique
  (kebab-case), enforced by a unique index; `body` is the markdown SKILL.md
  contents; `metadata` is optional free-form JSON.
  """

  use Ecto.Migration

  def up do
    create table(:skills, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text, null: false
      add :body, :text, null: false
      add :metadata, :map, default: %{}

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:skills, [:name], name: "skills_unique_name_index")
  end

  def down do
    drop_if_exists unique_index(:skills, [:name], name: "skills_unique_name_index")
    drop table(:skills)
  end
end
