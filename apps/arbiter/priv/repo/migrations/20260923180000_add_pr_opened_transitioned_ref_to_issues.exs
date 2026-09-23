defmodule Arbiter.Repo.Migrations.AddPrOpenedTransitionedRefToIssues do
  @moduledoc """
  Adds `pr_opened_transitioned_ref` to `issues` (bd-bqlwjo).

  Nullable, no backfill required, safe to hot-run against a live database.

  `pr_opened_transitioned_ref` — the PR/MR URL `Arbiter.Trackers.Sync` last
  successfully drove the `:pr_opened` status transition for. Tracked
  separately from `pr_opened_notified_ref` (the comment/remote-link
  watermark) so a first attempt that escalates (blank gated fields, a
  transient tracker failure) still retries the transition on the next run
  for the same PR ref, even though the comment must not repeat.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :pr_opened_transitioned_ref, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :pr_opened_transitioned_ref
    end
  end
end
