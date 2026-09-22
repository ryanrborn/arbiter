defmodule Arbiter.Repo.Migrations.DropGraphsAndGraphMembers do
  @moduledoc """
  Drops the `graphs` and `graph_members` tables (bd-a14qd1).

  Workflow Graphs and the Conductor that drove them are gone: the board
  scheduler (Autopilot) is the only dispatcher, and it already gates dispatch
  on the `dependencies` edges — including `conflicts_with` since bd-6bax7s —
  so nothing reads these tables any more.

  **This drops graph history.** That is intended and was signed off by the
  operator: at the time of writing, all 26 `graphs` rows were `drained`,
  `paused` or `draft` (none `running`) and every one of the 153
  `graph_members` rows pointed at a closed issue, so no open work is
  stranded. Re-confirm that before deploying against another install:

      SELECT run_state, COUNT(*) FROM graphs GROUP BY run_state;
      SELECT COUNT(*) FROM graph_members m
        JOIN issues i ON i.id = m.issue_id
       WHERE i.status NOT IN ('closed');

  `down/0` recreates the empty tables so a rollback leaves a schema the old
  code can boot against; the rows themselves are not recoverable from here.
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:graph_members, [:graph_id, :issue_id],
                     name: "graph_members_unique_membership_index"
                   )

    drop_if_exists table(:graph_members)
    drop_if_exists table(:graphs)
  end

  def down do
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

      add :repo, :text

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:graph_members, [:graph_id, :issue_id],
             name: "graph_members_unique_membership_index"
           )
  end
end
