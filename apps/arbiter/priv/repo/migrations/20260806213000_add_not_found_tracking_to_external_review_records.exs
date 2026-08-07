defmodule Arbiter.Repo.Migrations.AddNotFoundTrackingToExternalReviewRecords do
  @moduledoc """
  Adds `not_found_count` and `gone_at` columns to `external_review_records` (bd-7qzqfs).

  A bare 404 from a merge adapter is not proof a PR was deleted — GitHub also
  returns 404 (not 403) when a token transiently lacks read access, to avoid
  leaking the existence of private resources. `not_found_count` lets
  `Arbiter.Reviews.PrState` require several consecutive 404s before committing
  the terminal `pr_state` "gone", and `gone_at` lets it periodically re-verify
  a "gone" record instead of freezing it forever.
  """

  use Ecto.Migration

  def up do
    alter table(:external_review_records) do
      add :not_found_count, :bigint, null: false, default: 0
      add :gone_at, :utc_datetime
    end
  end

  def down do
    alter table(:external_review_records) do
      remove :gone_at
      remove :not_found_count
    end
  end
end
