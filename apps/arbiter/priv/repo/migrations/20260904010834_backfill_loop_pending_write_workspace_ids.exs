defmodule Arbiter.Repo.Migrations.BackfillLoopPendingWriteWorkspaceIds do
  @moduledoc """
  bd-3dasqm: backfill `workspace_id` on historical `loop_pending_writes` rows
  written NULL as a (mistaken) fleet-scope marker. See
  `Arbiter.Loop.PendingWriteWorkspaceBackfill` for the recovery rule and why
  this is a one-time repair rather than an ongoing job.
  """

  use Ecto.Migration

  def up do
    for %{scope: scope, before: before, backfilled: backfilled, unresolved: unresolved} <-
          Arbiter.Loop.PendingWriteWorkspaceBackfill.run() do
      IO.puts(
        "[backfill_loop_pending_write_workspace_ids] scope=#{scope}: #{before} row(s) had a " <>
          "NULL workspace_id; backfilled #{backfilled}; #{unresolved} unresolvable remaining " <>
          "(no attributable task, or an ambiguous install with no default workspace)."
      )
    end
  end

  def down do
    :ok
  end
end
