defmodule Arbiter.Repo.Migrations.AddCircuitBreakerShaToIssues do
  @moduledoc """
  Adds `circuit_breaker_sha` to `issues` (bd-wtvu9r).

  Nullable, no backfill required, safe to hot-run against a live database.

  `circuit_breaker_sha` — the PR head SHA ReviewPatrol's circuit breaker last
  tripped at. The bd-1atwts arms only trip on an unchanged head (so for them it
  equals `last_verdict_sha`), but the answered-findings arm trips on a head that
  has moved past the verdicted commit; the resume path needs the tripped head
  itself to watermark `circuit_breaker_cleared_sha` correctly.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :circuit_breaker_sha, :string
    end
  end

  def down do
    alter table(:issues) do
      remove :circuit_breaker_sha
    end
  end
end
