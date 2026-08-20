defmodule Arbiter.Repo.Migrations.AddBaseTaskIdAndRoleToUsageEvents do
  @moduledoc """
  Adds `base_task_id` and `role` columns to `usage_events` (bd-5fhyry).

  Cost data for ReviewGate review/impl passes was previously queried via
  suffix stripping on task_id (e.g. "base#review" -> "base"), which was
  fragile and error-prone. Adding real columns lets task_costs_usd/1 group
  on `base_task_id` directly.

  These columns are nullable for backfill purposes; new events populate them
  when the worker creates the Usage.Event row (from base_task_id derived from
  task_id, and role derived from the worker meta).
  """

  use Ecto.Migration

  def up do
    alter table(:usage_events) do
      add(:base_task_id, :text)
      add(:role, :text)
    end

    create index(:usage_events, [:base_task_id, :occurred_at])
  end

  def down do
    drop_if_exists index(:usage_events, [:base_task_id, :occurred_at])

    alter table(:usage_events) do
      remove(:role)
      remove(:base_task_id)
    end
  end
end
