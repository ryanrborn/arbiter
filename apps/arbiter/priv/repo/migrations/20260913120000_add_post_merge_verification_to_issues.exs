defmodule Arbiter.Repo.Migrations.AddPostMergeVerificationToIssues do
  @moduledoc """
  Adds the post-merge verification fields to `issues` (bd-9so315).

  All nullable (or defaulted), no backfill required, safe to hot-run against a
  live database.

    * `verify_after_deploy` — when true, a merge parks the task at
      `:awaiting_verification` instead of closing it.
    * `awaiting_verification_at` — when the task entered that state; the board
      and `arb prime` render its age from this.
    * `verification_outcome` — `"observed"` / `"failed"`, the recorded result.
    * `verification_evidence` — the free-text evidence the coordinator recorded.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :verify_after_deploy, :boolean, default: false
      add :awaiting_verification_at, :utc_datetime_usec
      add :verification_outcome, :text
      add :verification_evidence, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :verification_evidence
      remove :verification_outcome
      remove :awaiting_verification_at
      remove :verify_after_deploy
    end
  end
end
