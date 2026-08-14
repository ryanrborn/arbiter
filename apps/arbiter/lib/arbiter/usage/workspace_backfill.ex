defmodule Arbiter.Usage.WorkspaceBackfill do
  @moduledoc """
  bd-93ru7w: one-time recovery of `workspace_id` on historical `usage_events`
  and `worker_runs` rows written NULL by ReviewGate-spawned reviewer/
  implementer workers.

  `Arbiter.Worker.ReviewGate.spawn_worker/5` starts those workers with
  `workspace_id: nil` deliberately, to keep the synthetic review/impl task id
  out of Admiral notifications and MergeQueue pickup. That same nil leaked
  into the usage ledger, making `Arbiter.Usage.summarize/1` blind to review
  and rework spend. `Arbiter.Worker.effective_workspace_id/1` fixes new rows
  at write time; this module repairs the historical ones.

  Recovers the real workspace by stripping the ReviewGate synthetic-id suffix
  (`#review`, `#impl<N>`, `#r<N>`, `#v<N>`, `#t<N>`, or a chain of these) back
  to the authoring task id — the same rule as
  `Arbiter.Worker.ReviewGate.base_task_id/1` — and looking up that task's
  `workspace_id` on `issues`. A row whose base task no longer exists, or whose
  base task itself has no workspace (a genuinely workspace-less ad-hoc run),
  is left NULL and counted as unresolvable rather than silently dropped.

  Plain SQL rather than Ash/Ecto.Query: this runs from inside an
  `Ecto.Migration` (see `priv/repo/migrations/20260729200000_*.exs`), where
  only the repo — not the full OTP application — is guaranteed started.
  """

  alias Arbiter.Repo

  @tables ~w(usage_events worker_runs)

  @type report :: %{
          table: String.t(),
          before: non_neg_integer(),
          backfilled: non_neg_integer(),
          unresolved: non_neg_integer()
        }

  @doc "Backfill every affected table. Returns one report per table."
  @spec run() :: [report()]
  def run, do: Enum.map(@tables, &backfill_table/1)

  defp backfill_table(table) do
    before_count = null_count(table)

    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE #{table}
        SET workspace_id = (
          SELECT i.workspace_id FROM issues i WHERE i.id = #{base_task_id_sql(table)}
        )
        WHERE workspace_id IS NULL
        AND EXISTS (
          SELECT 1 FROM issues i
          WHERE i.id = #{base_task_id_sql(table)} AND i.workspace_id IS NOT NULL
        )
        """,
        []
      )

    after_count = null_count(table)

    %{table: table, before: before_count, backfilled: updated, unresolved: after_count}
  end

  defp null_count(table) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM #{table} WHERE workspace_id IS NULL", [])

    count
  end

  # Base task id: everything before the first '#', or the whole id when there
  # is none — same rule as Arbiter.Worker.ReviewGate.base_task_id/1.
  defp base_task_id_sql(table) do
    "CASE WHEN instr(#{table}.task_id, '#') > 0 " <>
      "THEN substr(#{table}.task_id, 1, instr(#{table}.task_id, '#') - 1) " <>
      "ELSE #{table}.task_id END"
  end
end
