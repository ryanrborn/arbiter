defmodule Arbiter.Repo.Migrations.BackfillUsageWorkspaceIds do
  @moduledoc """
  bd-93ru7w: backfill `workspace_id` on historical `usage_events` and
  `worker_runs` rows written NULL by ReviewGate-spawned reviewer/implementer
  workers. See `Arbiter.Usage.WorkspaceBackfill` for the recovery rule and why
  this is a one-time repair rather than an ongoing job.
  """

  use Ecto.Migration

  def up do
    for %{table: table, before: before, backfilled: backfilled, unresolved: unresolved} <-
          Arbiter.Usage.WorkspaceBackfill.run() do
      IO.puts(
        "[backfill_usage_workspace_ids] #{table}: #{before} row(s) had a NULL workspace_id; " <>
          "backfilled #{backfilled}; #{unresolved} unresolvable remaining " <>
          "(base task deleted or itself workspace-less)."
      )
    end
  end

  def down do
    :ok
  end
end
