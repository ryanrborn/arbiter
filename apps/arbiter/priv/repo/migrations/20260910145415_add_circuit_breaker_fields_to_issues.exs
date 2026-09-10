defmodule Arbiter.Repo.Migrations.AddCircuitBreakerFieldsToIssues do
  @moduledoc """
  Adds ReviewPatrol per-engagement circuit breaker fields to `issues` (bd-1atwts).

  All columns are nullable with a safe default and require no backfill, so this
  migration is safe to hot-run against a live database.

  - `last_verdict` — the verdict ReviewPatrol last posted to the PR (`:approve`
    or `:request_changes`).
  - `last_verdict_sha` — the PR head SHA that verdict was posted against, so a
    would-be repeat verdict on the same commit can be detected.
  - `circuit_breaker_tripped` — whether the loop-signature circuit breaker has
    fired for this engagement; while true, ReviewPatrol posts nothing further.
  - `circuit_breaker_reason` — human-readable reason recorded when the breaker
    tripped, for the coordinator escalation and any later audit.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :last_verdict, :string
      add :last_verdict_sha, :string
      add :circuit_breaker_tripped, :boolean, default: false
      add :circuit_breaker_reason, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :last_verdict
      remove :last_verdict_sha
      remove :circuit_breaker_tripped
      remove :circuit_breaker_reason
    end
  end
end
