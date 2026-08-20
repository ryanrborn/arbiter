defmodule Arbiter.Repo.Migrations.AddBaseTaskIdAndRoleToWorkerRuns do
  @moduledoc """
  Adds `base_task_id` and `role` columns to `worker_runs` (bd-5fhyry).

  Replace suffix-encoded task-id hierarchy (`<base>#review`,
  `<base>#review#impl1`) with real columns: `base_task_id` (the root task)
  plus `role` (denoting the run's purpose), so hierarchy stops being string
  surgery that a `WHERE task_id = ...` silently drops.

  These columns are nullable for backfill purposes; new runs populate them
  from the task_id and ReviewGate state.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:base_task_id, :text)
      add(:role, :text)
    end

    create index(:worker_runs, [:base_task_id, :started_at])
  end

  def down do
    drop_if_exists index(:worker_runs, [:base_task_id, :started_at])

    alter table(:worker_runs) do
      remove(:role)
      remove(:base_task_id)
    end
  end
end
