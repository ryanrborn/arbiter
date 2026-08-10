defmodule Arbiter.Repo.Migrations.CreateSkillsUsage do
  @moduledoc """
  Hand-written, like `20260728211544_version_scope_skills_and_paper_trail.exs`,
  to avoid the ash_sqlite generator folding in unrelated snapshot drift from
  resources that already changed on main (bead_id→task_id renames, quota
  tables, external_review_records, …).
  """

  use Ecto.Migration

  def change do
    create table(:skills_usage, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :skill_id,
          references(:skills,
            column: :id,
            name: "skills_usage_skill_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      # bd-61hnbb: Ash's :integer attribute type maps to :bigint in sqlite
      # migrations (see other resource_snapshots) — match that.
      add :materialize_count, :bigint, default: 0, null: false
      add :invoke_count, :bigint, default: 0, null: false
      add :patch_count, :bigint, default: 0, null: false
      add :last_materialized_at, :utc_datetime
      add :last_invoked_at, :utc_datetime
      add :last_patched_at, :utc_datetime

      # bd-61hnbb: create_timestamp/update_timestamp default to
      # Ash.Type.UtcDatetimeUsec, not :utc_datetime — match that so the
      # migration and resource_snapshot agree with what the resource declares.
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skills_usage, [:skill_id], name: "skills_usage_unique_skill_index")
  end
end
