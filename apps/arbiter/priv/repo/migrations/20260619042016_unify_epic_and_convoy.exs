defmodule Arbiter.Repo.Migrations.UnifyEpicAndConvoy do
  @moduledoc """
  Unify the epic (`issue_type`) and convoy/batch grouping concepts into one
  parent-with-progress bead.

  * Adds `issues.auto_close` — when set, a parent bead closes automatically once
    all its `:parent_of` children are closed (mirrors the old convoy
    `system_managed` vs `owned` lifecycle).
  * Drops the `Convoy` + `ConvoyMembership` tables. No data migration is needed:
    there are no convoys in any live workspace (`convoy_list` == 0). Progress
    rollup is now computed over `:parent_of` dependency edges (see
    `Arbiter.Beads.Issue.Calcs`).

  The `auto_close` column follows this schema's convention of carrying attribute
  defaults at the Ash application layer rather than as DB-level defaults; it is
  added to the (empty in fresh installs) `issues` table as `null: false`.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :auto_close, :boolean, null: false
    end

    drop_if_exists unique_index(:convoy_memberships, [:convoy_id, :issue_id],
                     name: "convoy_memberships_convoy_issue_unique_index"
                   )

    drop_if_exists table(:convoy_memberships)
    drop_if_exists table(:convoys)
  end

  def down do
    create table(:convoys, primary_key: false) do
      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "convoys_workspace_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :closed_reason, :text
      add :closed_at, :utc_datetime_usec
      add :lifecycle, :text, null: false
      add :status, :text, null: false
      add :title, :text, null: false
      add :id, :text, null: false, primary_key: true
    end

    create table(:convoy_memberships, primary_key: false) do
      add :issue_id,
          references(:issues,
            column: :id,
            name: "convoy_memberships_issue_id_fkey",
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :convoy_id,
          references(:convoys,
            column: :id,
            name: "convoy_memberships_convoy_id_fkey",
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :id, :uuid, null: false, primary_key: true
    end

    create unique_index(:convoy_memberships, [:convoy_id, :issue_id],
             name: "convoy_memberships_convoy_issue_unique_index"
           )

    alter table(:issues) do
      remove :auto_close
    end
  end
end
