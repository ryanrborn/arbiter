defmodule Arbiter.Repo.Migrations.AddReportOnlyToExternalReviewRecords do
  @moduledoc """
  Adds the report-only / propose review-mode columns to
  `external_review_records` (bd-36qzgx):

    - `mode`              — "auto" | "report_only" (default "auto").
    - `proposed_comments` — JSON array of the per-finding proposed inline
                            comments captured by a report-only review (posted
                            nothing to the PR); the greenlight step posts the
                            coordinator-approved subset.
    - `greenlight_status` — "pending" | "posted" | "none" for a report-only
                            review; nil for an auto review.

  Safe for hot-run: ALTER TABLE ADD COLUMN with defaults / nullable, no
  rewrite of existing rows.
  """

  use Ecto.Migration

  def up do
    alter table(:external_review_records) do
      add :mode, :text, default: "auto"
      add :proposed_comments, {:array, :map}, default: []
      add :greenlight_status, :text
    end
  end

  def down do
    alter table(:external_review_records) do
      remove :mode
      remove :proposed_comments
      remove :greenlight_status
    end
  end
end
