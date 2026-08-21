defmodule Arbiter.Repo.Migrations.AddStopCategoryToWorkerRuns do
  @moduledoc """
  Adds `worker_runs.stop_category` (bd-apwfmy).

  `Arbiter.Worker.StopReason.classify/2` computes a **typed** category for
  every subprocess stop (`:auth_expired`, `:context_thrash`,
  `:exited_without_done`, ...) and Arbiter kept only the English sentence it
  renders into `failure_reason`. Every later consumer then re-derived the type
  with a regex over transcript prose. This column keeps the type.

  Nullable and never backfilled: nil means "this run did not end in a
  classified subprocess stop, or predates the column" — the same honest-null
  convention as the provenance block and `usage_events.cost_note`.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:stop_category, :text)
    end

    create index(:worker_runs, [:stop_category])
  end

  def down do
    drop_if_exists index(:worker_runs, [:stop_category])

    alter table(:worker_runs) do
      remove(:stop_category)
    end
  end
end
