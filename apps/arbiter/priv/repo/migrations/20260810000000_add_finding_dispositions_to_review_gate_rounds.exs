defmodule Arbiter.Repo.Migrations.AddFindingDispositionsToReviewGateRounds do
  @moduledoc """
  Adds `finding_ids` / `dispositions` / `undispositioned_count` to
  `review_gate_rounds` (bd-6r8caj / #1137).

  Gives a finding an identity that survives the round boundary. `finding_ids` is
  the JSON array of `F<round>.<n>` ids a `:review` round raised;
  `dispositions` is the JSON object mapping every finding carried INTO that round
  to what the round said about it (`addressed` / `not_addressed` / `obsolete` /
  `none`); `undispositioned_count` is how many Medium-or-higher carried findings
  the round left unaccounted for.

  This is what makes the bd-8mtb0q defect queryable instead of recoverable only
  by re-reading reviewer prose: an APPROVE row with a non-zero
  `undispositioned_count`, or a `dispositions` entry of `"none"`, IS the failure.

  All three nullable: nil on `:impl` rows and on `:review` rounds with nothing
  carried in (round 1). Hand-written (not generated): the Ash snapshot generator
  folds in unrelated drift.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :finding_ids, :text
      add :dispositions, :text
      add :undispositioned_count, :integer
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :undispositioned_count
      remove :dispositions
      remove :finding_ids
    end
  end
end
