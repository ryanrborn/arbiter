defmodule Arbiter.Repo.Migrations.AddReviewPatrolCapFieldsToIssues do
  @moduledoc """
  Adds ReviewPatrol per-PR review cap fields to `issues` (bd-ahvk03).

  Both columns are nullable with a safe default and require no backfill, so this
  migration is safe to hot-run against a live database.

  - `review_count` — number of re-reviews ReviewPatrol has posted to the PR;
    the cap counter.
  - `review_cap_escalated` — whether the cap-reached escalation has already
    been raised for this engagement, so it fires exactly once.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :review_count, :integer, default: 0
      add :review_cap_escalated, :boolean, default: false
    end
  end

  def down do
    alter table(:issues) do
      remove :review_count
      remove :review_cap_escalated
    end
  end
end
