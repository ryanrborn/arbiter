defmodule Arbiter.Repo.Migrations.IndexUsageEventsWorkerRunId do
  use Ecto.Migration

  def up do
    create index(:usage_events, [:worker_run_id])
  end

  def down do
    drop_if_exists index(:usage_events, [:worker_run_id],
                     name: "usage_events_worker_run_id_index")
  end
end
