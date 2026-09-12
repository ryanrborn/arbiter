defmodule Arbiter.Repo.Migrations.AddCommitGateToReviewGateRounds do
  @moduledoc """
  Adds `commit_gate` to `review_gate_rounds` (bd-2eyf9y / #1575).

  Records which commit-gate outcome an `:impl` round hit, if any:
  `reprompted` (dirty tree, implementer resumed once), `escalated_uncommitted`
  (still dirty after that resume), or `escalated_no_changes` (clean tree, HEAD
  unchanged — the round produced no code change). Nil for a round whose HEAD
  advanced normally, for a round with no worktree to check, and for every
  `:review` row.

  Hand-written (not generated): the Ash snapshot generator folds in unrelated
  drift, per the neighboring `add_finding_dispositions_to_review_gate_rounds`
  migration.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :commit_gate, :string
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :commit_gate
    end
  end
end
