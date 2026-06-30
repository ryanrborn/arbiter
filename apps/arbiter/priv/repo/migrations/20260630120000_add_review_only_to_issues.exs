defmodule Arbiter.Repo.Migrations.AddReviewOnlyToIssues do
  @moduledoc """
  Adds the `review_only` boolean column to `issues` (bd-6xaaam).

  A review-only task is one dispatched via `worker_review` — it reads a
  colleague's PR and posts a verdict, but must NEVER mutate the linked tracker
  issue (no reassignment, no description sync, no status transition).

  Nullable (nil treated as false) so existing rows don't need a backfill;
  Ash coerces nil → false via the attribute default.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :review_only, :boolean, default: false
    end
  end

  def down do
    alter table(:issues) do
      remove :review_only
    end
  end
end
