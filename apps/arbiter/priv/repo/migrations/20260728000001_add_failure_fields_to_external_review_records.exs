defmodule Arbiter.Repo.Migrations.AddFailureFieldsToExternalReviewRecords do
  @moduledoc """
  Adds `failure_stage` and `failure_reason` columns to `external_review_records` (bd-7rspia).

  When a review fails, these fields capture where the failure occurred and why,
  making diagnosis possible through MCP without requiring ssh + journalctl.

  `failure_stage` tracks which phase failed: read_diff, file_findings, agent, tracker_context.
  `failure_reason` stores the normalized error kind, status, and message.
  """

  use Ecto.Migration

  def up do
    alter table(:external_review_records) do
      add :failure_stage, :string
      add :failure_reason, :string
    end
  end

  def down do
    alter table(:external_review_records) do
      remove :failure_reason
      remove :failure_stage
    end
  end
end
