defmodule Arbiter.Repo.Migrations.AddRunProvenanceToWorkerRuns do
  @moduledoc """
  Adds run-provenance columns to `worker_runs` (bd-dzz6ly, loop-engineering
  epic gap G5): what *governed* the run, not just what happened.

    - `resolved_skills`         — JSON array of `{name, activation_mode,
                                  skill_version}` for the effective
                                  post-layering skill set.
    - `standing_orders_digest`  — SHA-256 hex of the workspace's effective
                                  standing_orders text at dispatch time.
    - `routing_policy`          — which routing policy decided
                                  ("static" / "by_priority" / "by_difficulty" /
                                  "by_budget" / "round_robin" / "review_agent").
    - `model_tier`              — resolved abstract tier ("economy" /
                                  "standard" / "premium").
    - `thinking`                — resolved abstract reasoning effort ("none" /
                                  "low" / "medium" / "high").
    - `difficulty_at_dispatch`  — the task's difficulty AT DISPATCH TIME
                                  (immune to a later difficulty edit).

  All nullable; backfill for pre-existing rows is explicitly out of scope —
  provenance recording starts 2026-07-29.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:resolved_skills, {:array, :map}, default: [])
      add(:standing_orders_digest, :text)
      add(:routing_policy, :text)
      add(:model_tier, :text)
      add(:thinking, :text)
      add(:difficulty_at_dispatch, :integer)
    end
  end

  def down do
    alter table(:worker_runs) do
      remove(:difficulty_at_dispatch)
      remove(:thinking)
      remove(:model_tier)
      remove(:routing_policy)
      remove(:standing_orders_digest)
      remove(:resolved_skills)
    end
  end
end
