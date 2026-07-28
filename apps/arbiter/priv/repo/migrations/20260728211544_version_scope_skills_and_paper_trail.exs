defmodule Arbiter.Repo.Migrations.VersionScopeSkillsAndPaperTrail do
  @moduledoc """
  bd-9j6is7 — version + scope the mutable artifacts.

  Hand-written to a **focused** set of changes: the `ash_sqlite` generator folds
  in unrelated snapshot drift from resources that already changed on main
  (bead_id→task_id renames, quota tables, external_review_records, …). Those are
  deliberately excluded — this migration touches only `skills` + `workspaces`
  and their new paper-trail version tables.

    * `skills`  — add `workspace_id` (nullable FK → workspaces; nil = global),
      add `actor` (last-editor label), and swap the `unique_name` index from
      `[:name]` to `[:name, :workspace_id]` with `nulls_distinct: false` so the
      two nil-workspace globals still collide (global uniqueness) while a scoped
      skill may reuse a global's name.
    * `workspaces` — add `actor`.
    * `skills_versions` / `workspaces_versions` — AshPaperTrail version tables.
  """

  use Ecto.Migration

  def up do
    # ---- workspaces + its version table ---------------------------------
    create table(:workspaces_versions, primary_key: false) do
      add :version_updated_at, :utc_datetime_usec, null: false
      add :version_inserted_at, :utc_datetime_usec, null: false
      add :changes, :map
      # No FK to :workspaces (reference_source?: false) so a workspace can be
      # deleted without its history blocking the destroy.
      add :version_source_id, :uuid, null: false
      add :actor, :text
      add :config, :map, default: %{}
      add :version_action_name, :text, null: false
      add :version_action_type, :text, null: false
      add :id, :uuid, null: false, primary_key: true
    end

    alter table(:workspaces) do
      add :actor, :text
    end

    # ---- skills + its version table -------------------------------------
    create table(:skills_versions, primary_key: false) do
      add :version_updated_at, :utc_datetime_usec, null: false
      add :version_inserted_at, :utc_datetime_usec, null: false
      add :changes, :map
      # No FK to :skills (reference_source?: false) so a skill can be deleted
      # without its version history blocking the destroy.
      add :version_source_id, :uuid, null: false
      add :actor, :text
      add :metadata, :map, default: %{}
      add :body, :text, null: false
      add :version_action_inputs, :map, null: false
      add :version_action_name, :text, null: false
      add :version_action_type, :text, null: false
      add :id, :uuid, null: false, primary_key: true
    end

    alter table(:skills) do
      add :actor, :text

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "skills_workspace_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          )
    end

    # Scoped uniqueness: at most one skill per (name, workspace). SQLite treats
    # the NULL workspace_id of globals as distinct, so this alone does NOT stop
    # two same-named globals — the partial index below does.
    drop_if_exists unique_index(:skills, [:name], name: "skills_unique_name_index")

    create unique_index(:skills, [:name, :workspace_id], name: "skills_unique_name_index")

    # Global uniqueness: at most one `name` among global (NULL-workspace) skills.
    create unique_index(:skills, [:name],
             where: "workspace_id IS NULL",
             name: "skills_unique_global_name_index"
           )
  end

  def down do
    drop_if_exists unique_index(:skills, [:name], name: "skills_unique_global_name_index")

    drop_if_exists unique_index(:skills, [:name, :workspace_id], name: "skills_unique_name_index")

    create unique_index(:skills, [:name], name: "skills_unique_name_index")

    alter table(:skills) do
      remove :workspace_id
      remove :actor
    end

    drop table(:skills_versions)

    alter table(:workspaces) do
      remove :actor
    end

    drop table(:workspaces_versions)
  end
end
