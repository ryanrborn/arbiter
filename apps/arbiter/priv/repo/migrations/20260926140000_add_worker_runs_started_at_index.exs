defmodule Arbiter.Repo.Migrations.AddWorkerRunsStartedAtIndex do
  use Ecto.Migration

  def change do
    create index(:worker_runs, [:started_at])
  end
end
