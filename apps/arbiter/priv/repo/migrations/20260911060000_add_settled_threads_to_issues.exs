defmodule Arbiter.Repo.Migrations.AddSettledThreadsToIssues do
  @moduledoc """
  Adds `settled_threads` to `issues` (bd-cccjtn).

  Nullable with a safe default and no backfill, so this migration is safe to
  hot-run against a live database. Existing engagements start with no settled
  threads, which is exactly today's behaviour.

  `settled_threads` — JSON array of the review threads on the engagement's PR
  that are closed (author refuted with cited evidence / we conceded / resolved).
  ReviewPatrol's re-review pass reads it to avoid re-raising a settled finding.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :settled_threads, {:array, :map}, default: []
    end
  end

  def down do
    alter table(:issues) do
      remove :settled_threads
    end
  end
end
