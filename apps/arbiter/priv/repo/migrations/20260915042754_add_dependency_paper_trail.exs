defmodule Arbiter.Repo.Migrations.AddDependencyPaperTrail do
  @moduledoc """
  bd-apj0gq — audit dependency edges.

  `Arbiter.Tasks.Dependency` gains `AshPaperTrail.Resource`, so every edge
  create/destroy writes a version row. The `dependencies` table itself is
  untouched — this migration only adds `dependencies_versions`.

  Hand-written to a **focused** set of changes: `mix ash_sqlite.generate_migrations`
  folds in unrelated snapshot drift from resources whose hand-written migrations
  never shipped a snapshot (quota tables, review_coverage, external_review_records,
  …). Those are deliberately excluded, same as bd-9j6is7's migration.

  `attributes_as_attributes([:from_issue_id, :to_issue_id, :type])` puts the
  edge's identity on every row, so a destroy version still says *which* edge went
  away; `reference_source?(false)` means no FK back to `dependencies`, so
  destroying an edge is never blocked by its own history.
  """

  use Ecto.Migration

  def up do
    create table(:dependencies_versions, primary_key: false) do
      add :version_updated_at, :utc_datetime_usec, null: false
      add :version_inserted_at, :utc_datetime_usec, null: false
      add :changes, :map
      # No FK to :dependencies (reference_source?: false) — an edge is destroyed,
      # not archived, and its history must not restrict the destroy.
      add :version_source_id, :uuid, null: false
      add :type, :text, null: false
      add :to_issue_id, :text, null: false
      add :from_issue_id, :text, null: false
      add :version_action_inputs, :map, null: false
      add :version_action_name, :text, null: false
      add :version_action_type, :text, null: false
      add :id, :uuid, null: false, primary_key: true
    end

    create index(:dependencies_versions, [:version_source_id])
    # The ACTIVITY panel asks "what happened to this task's edges?", which is a
    # lookup by endpoint, not by edge id.
    create index(:dependencies_versions, [:from_issue_id])
    create index(:dependencies_versions, [:to_issue_id])
  end

  def down do
    drop_if_exists index(:dependencies_versions, [:to_issue_id])
    drop_if_exists index(:dependencies_versions, [:from_issue_id])
    drop_if_exists index(:dependencies_versions, [:version_source_id])
    drop table(:dependencies_versions)
  end
end
