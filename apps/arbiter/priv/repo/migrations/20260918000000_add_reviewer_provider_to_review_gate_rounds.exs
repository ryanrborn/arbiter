defmodule Arbiter.Repo.Migrations.AddReviewerProviderToReviewGateRounds do
  @moduledoc """
  Adds `reviewer_provider` to `review_gate_rounds` (bd-3hb4ih).

  Records which agent provider actually ran a `:review` pass ("claude" /
  "gemini" / "codex"). Load-bearing for the reviewer print-timeout rotation: a
  `review_agent.type` pool writes one `:timed_out` row per provider that hit its
  own print-timeout wall, and the verdict row names the provider that finally
  produced the verdict. `reviewer_model` cannot answer that — a timed-out pass
  usually emits no usage event at all, so its model is nil.

  Nullable: nil for `:impl` rows, for pre-review escalations (no provider was
  ever reached) and for every row written before this migration.

  Hand-written (not generated): the Ash snapshot generator folds in unrelated
  drift.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :reviewer_provider, :text
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :reviewer_provider
    end
  end
end
