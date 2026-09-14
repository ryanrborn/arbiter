defmodule Arbiter.Repo.Migrations.AddReviewParkToIssues do
  @moduledoc """
  Adds the ReviewGate park flag to `issues` (bd-9zuvbh, design #1635 §5.3
  class C).

  Two nullable columns, no default and no backfill — safe to hot-run against
  the live database. Every existing issue starts unparked, which is exactly
  today's behaviour.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :review_park_reason, :text
      add :review_parked_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:issues) do
      remove :review_park_reason
      remove :review_parked_at
    end
  end
end
