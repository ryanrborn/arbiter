defmodule Arbiter.Repo.Migrations.AddPrOpenedNotifiedRefToIssues do
  @moduledoc """
  Adds `pr_opened_notified_ref` to `issues` (bd-bqlwjo).

  Nullable, no backfill required, safe to hot-run against a live database.

  `pr_opened_notified_ref` — the PR/MR URL `Arbiter.Trackers.Sync` last posted
  the "Arbiter opened a pull request for this ticket" comment for. A durable
  idempotency watermark so a repeat `:pr_opened` lifecycle event for the same
  PR (a ReviewGate implementation round, a `worker_resume`, a later worker run
  that simply re-resolves the same already-open PR) posts nothing, while a new
  PR after `task_reopen` still gets its own comment.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :pr_opened_notified_ref, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :pr_opened_notified_ref
    end
  end
end
