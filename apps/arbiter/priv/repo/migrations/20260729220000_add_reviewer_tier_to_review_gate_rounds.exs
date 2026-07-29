defmodule Arbiter.Repo.Migrations.AddReviewerTierToReviewGateRounds do
  @moduledoc """
  Adds `reviewer_tier` to `review_gate_rounds` (bd-3xultf).

  Records the abstract `model_tier` ("economy"/"standard"/"premium") resolved
  for a `:review` row alongside the existing `reviewer_model`, so convergence
  analysis can segment by (and control for) the judge's tier once the
  ReviewGate reviewer is routed by task difficulty instead of hard-pinned.
  Nullable: nil for `:impl` rows and for any review pass whose tier wasn't
  captured.

  Hand-written (not generated): the Ash snapshot generator folds in unrelated
  drift.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :reviewer_tier, :string
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :reviewer_tier
    end
  end
end
