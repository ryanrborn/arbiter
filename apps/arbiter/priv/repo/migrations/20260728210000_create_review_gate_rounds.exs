defmodule Arbiter.Repo.Migrations.CreateReviewGateRounds do
  @moduledoc """
  Creates the `review_gate_rounds` table (bd-aqyjuc / #1011 gap G2).

  One row per `Arbiter.Worker.ReviewGate` reviewer or implementer pass,
  written at verdict-parse time. Powers first-pass-convergence and
  finding-category queries without transcript parsing.

  Backfill is out of scope — rows only exist for ReviewGate runs from
  2026-07-28 onward.
  """

  use Ecto.Migration

  def up do
    create table(:review_gate_rounds, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :task_id, :string, null: false
      add :run_id, :uuid
      add :round, :integer, null: false
      add :role, :string, null: false
      add :verdict, :string
      add :findings, :text
      add :finding_count, :integer
      add :reviewer_model, :string
      add :cost_usd, :float
      add :converged, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:review_gate_rounds, [:task_id, :inserted_at])
    create index(:review_gate_rounds, [:task_id, :round])
  end

  def down do
    drop table(:review_gate_rounds)
  end
end
