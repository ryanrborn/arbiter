defmodule Arbiter.Repo.Migrations.CreateGraphs do
  @moduledoc """
  Creates the `graphs` and `graph_members` tables for `Arbiter.Tasks.Graph`
  and `Arbiter.Tasks.GraphMember`.

  A Graph is an execution unit: a named, workspace-scoped set of directives
  (Issues) that are executed together. Orthogonal to epics. Run states:
  draft → running ⇄ paused → drained.

  GraphMember is the join table linking a Graph to its member Issues. The
  unique index on (graph_id, issue_id) prevents duplicate memberships.
  Dependency edges between directives are NOT duplicated here — the existing
  `dependencies` table handles ordering.
  """

  use Ecto.Migration

  def up do
    create table(:graphs, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :run_state, :text, null: false, default: "draft"

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "graphs_workspace_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:graph_members, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :graph_id,
          references(:graphs,
            column: :id,
            name: "graph_members_graph_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :issue_id,
          references(:issues,
            column: :id,
            name: "graph_members_issue_id_fkey",
            type: :text,
            on_delete: :restrict
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:graph_members, [:graph_id, :issue_id],
             name: "graph_members_unique_membership_index"
           )
  end

  def down do
    drop_if_exists unique_index(:graph_members, [:graph_id, :issue_id],
                     name: "graph_members_unique_membership_index"
                   )

    drop_if_exists table(:graph_members)
    drop_if_exists table(:graphs)
  end
end
