defmodule Arbiter.Repo.Migrations.AddCircuitBreakerClearedShaToIssues do
  @moduledoc """
  Adds `circuit_breaker_cleared_sha` to `issues` (bd-1atwts).

  Nullable, no backfill required, safe to hot-run against a live database.

  `circuit_breaker_cleared_sha` — the PR head SHA in effect when a coordinator
  last cleared `circuit_breaker_tripped`. Watermarks a resume so the breaker
  doesn't immediately re-trip on the next tick against the same,
  already-adjudicated commit.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :circuit_breaker_cleared_sha, :string
    end
  end

  def down do
    alter table(:issues) do
      remove :circuit_breaker_cleared_sha
    end
  end
end
