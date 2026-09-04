defmodule Arbiter.Loop.PendingWriteWorkspaceBackfill do
  @moduledoc """
  bd-3dasqm: one-time recovery of `workspace_id` on historical
  `loop_pending_writes` rows written NULL as a (mistaken) fleet-scope marker —
  the same shape as #1011 Stage 0 defect G3 on `usage_events`, fixed in #1016
  and repaired here by `Arbiter.Usage.WorkspaceBackfill`, its model for this
  module.

  `Arbiter.Loop.record/2` now resolves a real `workspace_id` for every new
  `:fleet`-scoped row (see its `resolve_workspace_id/2`); this module repairs
  the rows written before that fix:

    * `scope = 'task'` rows are attributed via their `target` (the task id) —
      `issues.workspace_id` for that task.
    * `scope = 'fleet'` rows have no task to derive from, so they are
      attributed to the installation's default workspace: the sole workspace,
      or the one named `"default"` when there are several. An ambiguous
      install (several workspaces, none named `"default"`) is left NULL and
      counted as unresolved rather than guessed at — the same choice
      `Arbiter.Quota.default_workspace_id/0` makes for a live insert.

  Plain SQL rather than Ash/Ecto.Query: this runs from inside an
  `Ecto.Migration` (see `priv/repo/migrations/20260904010834_*.exs`), where
  only the repo — not the full OTP application — is guaranteed started.
  """

  alias Arbiter.Repo

  @type report :: %{
          scope: String.t(),
          before: non_neg_integer(),
          backfilled: non_neg_integer(),
          unresolved: non_neg_integer()
        }

  @doc "Backfill every NULL-`workspace_id` row. Returns one report per scope."
  @spec run() :: [report()]
  def run, do: [backfill_task_scoped(), backfill_fleet_scoped()]

  # `target` is the task id a task-scoped row was raised against (see
  # `Arbiter.Loop.Proposals.misestimate_candidates/3`).
  defp backfill_task_scoped do
    before_count = null_count("scope = 'task'")

    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE loop_pending_writes
        SET workspace_id = (SELECT i.workspace_id FROM issues i WHERE i.id = loop_pending_writes.target)
        WHERE workspace_id IS NULL
        AND scope = 'task'
        AND EXISTS (
          SELECT 1 FROM issues i
          WHERE i.id = loop_pending_writes.target AND i.workspace_id IS NOT NULL
        )
        """,
        []
      )

    after_count = null_count("scope = 'task'")

    %{scope: "task", before: before_count, backfilled: updated, unresolved: after_count}
  end

  defp backfill_fleet_scoped do
    before_count = null_count("scope = 'fleet'")

    updated =
      case Arbiter.Quota.default_workspace_id() do
        {:ok, ws_id} ->
          %{num_rows: n} =
            Repo.query!(
              "UPDATE loop_pending_writes SET workspace_id = ? WHERE workspace_id IS NULL AND scope = 'fleet'",
              [ws_id]
            )

          n

        {:error, _reason} ->
          0
      end

    after_count = null_count("scope = 'fleet'")

    %{scope: "fleet", before: before_count, backfilled: updated, unresolved: after_count}
  end

  # `where_clause` is never user input: both call sites pass a compile-time
  # literal (`"scope = 'task'"` / `"scope = 'fleet'"`).
  # sobelow_skip ["SQL.Query"]
  defp null_count(where_clause) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM loop_pending_writes WHERE workspace_id IS NULL AND #{where_clause}",
        []
      )

    count
  end
end
