defmodule Arbiter.Repo.Migrations.AddFailureSummaryToWorkerRuns do
  @moduledoc """
  Adds `worker_runs.failure_summary` (bd-2ddf2x).

  `failure_reason` stays a short atom-as-string for the ReviewGate-rejection
  path (`"review_gate_rejected"` / `"review_gate_inconclusive"`) since
  `Loop.FailureClassifier`, `Loop.Corpus.rejected?/1`, and `Loop.Analysis`
  pattern-match it literally. `failure_summary` is a bounded human-readable
  twin (ReviewGate VERDICT line + top finding, truncated) so `worker_runs`
  answers "why did this fail" without a separate `review_gate_rounds_list`
  call.

  Nullable and never backfilled: nil means "this run didn't fail via
  ReviewGate, or predates the column."
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:failure_summary, :text)
    end
  end

  def down do
    alter table(:worker_runs) do
      remove(:failure_summary)
    end
  end
end
