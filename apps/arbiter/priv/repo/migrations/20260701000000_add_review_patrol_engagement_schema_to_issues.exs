defmodule Arbiter.Repo.Migrations.AddReviewPatrolEngagementSchemaToIssues do
  @moduledoc """
  Adds ReviewPatrol engagement tracking fields to `issues` (bd-cw3w9p).

  All three columns are nullable text with no backfill required, so this
  migration is safe to hot-run against a live database.

  - `last_reviewed_sha`    — PR head SHA at our last posted review.
  - `last_seen_comment_id` — High-watermark cursor for author replies (Phase 2).
  - `review_automation`    — Engagement mode: "auto" | "flag" (nil = inherit
                             workspace policy, resolved in task B).
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :last_reviewed_sha, :text
      add :last_seen_comment_id, :text
      add :review_automation, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :last_reviewed_sha
      remove :last_seen_comment_id
      remove :review_automation
    end
  end
end
