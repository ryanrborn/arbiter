defmodule Arbiter.Repo.Migrations.AddPrStateToExternalReviewRecords do
  @moduledoc """
  Adds `pr_state` (nullable string) to `external_review_records` (bd-dsd67h).

  Stores the resolved PR state ("open" / "merged" / "closed") so the
  Review History dashboard panel can order open reviews first without a
  per-render adapter call for every row. Nullable — populated lazily on
  the first dashboard render; shows "unknown" until resolved.

  Safe for hot-run: ALTER TABLE ADD COLUMN with no NOT NULL constraint.
  """

  use Ecto.Migration

  def up do
    alter table(:external_review_records) do
      add :pr_state, :string
    end
  end

  def down do
    alter table(:external_review_records) do
      remove :pr_state
    end
  end
end
