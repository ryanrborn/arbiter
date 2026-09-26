defmodule Arbiter.Repo.Migrations.AddFixRoundAttemptToReviewGateRounds do
  @moduledoc """
  Adds `fix_round_attempt` to `review_gate_rounds` (bd-6d3h8m).

  `round` is 1-indexed WITHIN a single ReviewGate pass, and an automatic
  implementer fix round (bd-a9zb7w) re-attaches a fresh ReviewGate that starts
  again at `round: 1`. Without a second axis, a task that went through one fix
  round reports rounds 1-3 twice, and `review_gate_rounds_list`'s
  `round: :asc, inserted_at: :asc` sort interleaves the two passes instead of
  reading as two consecutive ones.

  `fix_round_attempt` is 0 for the original pass, N for the Nth automatic fix
  round — the same number already carried on the resumed worker's
  `meta[:review_gate_fix_round_attempts]`. Backfilled to 0 for every existing
  row via the column default, which is correct: no fix round existed before
  this migration ran.

  Hand-written (not generated): the Ash snapshot generator folds in unrelated
  drift, per the neighboring `reviewer_provider` migration.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :fix_round_attempt, :integer, default: 0, null: false
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :fix_round_attempt
    end
  end
end
