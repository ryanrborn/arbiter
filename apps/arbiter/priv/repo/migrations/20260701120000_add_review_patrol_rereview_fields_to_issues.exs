defmodule Arbiter.Repo.Migrations.AddReviewPatrolRereviewFieldsToIssues do
  @moduledoc """
  Adds ReviewPatrol new-commit re-review fields to `issues` (bd-f3fg22).

  Both columns are nullable with a safe default and require no backfill, so this
  migration is safe to hot-run against a live database.

  - `last_reviewed_at` — timestamp of the last posted re-review; ReviewPatrol's
    debounce cursor.
  - `posted_findings`  — JSON array of findings already posted on the PR
    (%{"file","line","message","severity"}); the source of truth for the
    re-review relevance gate and unchanged-finding de-dupe.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :last_reviewed_at, :utc_datetime
      add :posted_findings, {:array, :map}, default: []
    end
  end

  def down do
    alter table(:issues) do
      remove :last_reviewed_at
      remove :posted_findings
    end
  end
end
