defmodule Arbiter.Repo.Migrations.CreateExternalReviewRecords do
  @moduledoc """
  Creates the `external_review_records` table (bd-31fh9e).

  One row per ExternalReview run — inserted on dispatch (:running) and
  updated to :completed/:failed when the workflow finishes. Powers the
  dashboard "External Reviews" panel and the `/api/external_reviews` endpoint.

  ## Retention

  Records are kept indefinitely by default. See `Arbiter.Reviews` module doc
  for the recommended manual purge query.
  """

  use Ecto.Migration

  def up do
    create table(:external_review_records, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :pr_ref, :string, null: false
      add :pr, :string
      add :workspace_id, :string
      add :strategy, :string
      add :link, :string
      add :status, :string, null: false, default: "running"
      add :verdict, :string
      add :finding_count, :integer
      add :findings_summary, :text
      add :model, :string
      add :cost_usd, :float
      add :tokens_in, :integer
      add :tokens_out, :integer
      add :dispatched_by, :string
      add :engagement_id, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:external_review_records, [:workspace_id, :started_at])
    create index(:external_review_records, [:pr_ref])
    create index(:external_review_records, [:status, :started_at])
  end

  def down do
    drop table(:external_review_records)
  end
end
