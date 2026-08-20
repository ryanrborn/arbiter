defmodule Arbiter.Repo.Migrations.AddWorkerRunSteps do
  @moduledoc """
  Adds `worker_run_steps` (bd-7xftps / bd-apwfmy Phase 1): one row per
  matched `tool_use`/`tool_result` pair inside a Claude worker run, written
  from `Arbiter.Worker.ClaudeSession`'s existing emit path.
  """

  use Ecto.Migration

  def up do
    create table(:worker_run_steps, primary_key: false) do
      add :inserted_at, :utc_datetime_usec, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :output_summary, :text
      add :input_summary, :text
      add :input_digest, :text
      add :duration_ms, :bigint
      add :is_error, :boolean, null: false
      add :name, :text
      add :tool_use_id, :text, null: false
      add :task_id, :text
      add :run_id, :uuid
      add :id, :uuid, null: false, primary_key: true
    end

    create index(:worker_run_steps, ["name"])

    create index(:worker_run_steps, ["run_id", "occurred_at"])
  end

  def down do
    drop_if_exists index(:worker_run_steps, ["run_id", "occurred_at"],
                     name: "worker_run_steps_run_id_occurred_at_index"
                   )

    drop_if_exists index(:worker_run_steps, ["name"], name: "worker_run_steps_name_index")

    drop table(:worker_run_steps)
  end
end
