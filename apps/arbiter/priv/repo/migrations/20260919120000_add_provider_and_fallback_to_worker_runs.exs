defmodule Arbiter.Repo.Migrations.AddProviderAndFallbackToWorkerRuns do
  @moduledoc """
  Adds `provider` and `provider_fallback` columns to `worker_runs` (bd-2exkl0).
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :provider, :text
      add :provider_fallback, :text
    end

    create index(:worker_runs, [:provider])
  end

  def down do
    drop_if_exists index(:worker_runs, [:provider])

    alter table(:worker_runs) do
      remove :provider_fallback
      remove :provider
    end
  end
end
