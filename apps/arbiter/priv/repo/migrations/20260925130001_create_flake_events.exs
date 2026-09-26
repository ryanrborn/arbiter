defmodule Arbiter.Repo.Migrations.CreateFlakeEvents do
  @moduledoc """
  bd-6vullc: creates the append-only `flake_events` table. A fix_pass that
  concludes a CI failure was a flake or infra issue (re-ran with no code
  change) records one row here via `Arbiter.Loop.Flakes.record/1` — the
  MCP `flake_record` tool is the only writer.

  Written by hand, matching `create_review_coverage`: no matching
  `priv/resource_snapshots` entry is committed, so the next `mix
  ash.codegen` run will detect this resource as new and emit its own
  reconciliation migration, which should be a no-op or discarded rather
  than applied.
  """

  use Ecto.Migration

  def up do
    create table(:flake_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :task_id, :text, null: false
      add :run_id, :uuid
      add :repo, :text, null: false
      add :ci_job, :text, null: false
      add :test_file, :text
      add :test_line, :bigint
      add :signature, :text, null: false
      add :note, :text
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:flake_events, [:task_id], name: "flake_events_task_id_index")
    create index(:flake_events, [:repo, :signature], name: "flake_events_repo_signature_index")

    create index(:flake_events, [:repo, :test_file, :test_line],
             name: "flake_events_repo_test_index"
           )

    create index(:flake_events, [:recorded_at], name: "flake_events_recorded_at_index")
  end

  def down do
    drop_if_exists index(:flake_events, [:recorded_at], name: "flake_events_recorded_at_index")

    drop_if_exists index(:flake_events, [:repo, :test_file, :test_line],
                     name: "flake_events_repo_test_index"
                   )

    drop_if_exists index(:flake_events, [:repo, :signature],
                     name: "flake_events_repo_signature_index"
                   )

    drop_if_exists index(:flake_events, [:task_id], name: "flake_events_task_id_index")

    drop table(:flake_events)
  end
end
