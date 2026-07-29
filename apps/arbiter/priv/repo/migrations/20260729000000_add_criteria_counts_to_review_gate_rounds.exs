defmodule Arbiter.Repo.Migrations.AddCriteriaCountsToReviewGateRounds do
  @moduledoc """
  Adds `criteria_total` / `criteria_unmet` to `review_gate_rounds` (bd-4yhv4x).

  Records the reviewer's per-criterion CRITERIA breakdown structurally — how
  many acceptance criteria the pass addressed and how many it marked
  `[NOT MET]` — so "APPROVE with N criteria unmet" is queryable without
  re-reading the reviewer transcript. Both nullable: nil on `:impl` rows and on
  `:review` rows for tasks with no stated acceptance criteria.

  Hand-written (not generated): the Ash snapshot generator folds in unrelated
  drift.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :criteria_total, :integer
      add :criteria_unmet, :integer
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :criteria_unmet
      remove :criteria_total
    end
  end
end
