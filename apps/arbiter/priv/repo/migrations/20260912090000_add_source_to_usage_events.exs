defmodule Arbiter.Repo.Migrations.AddSourceToUsageEvents do
  @moduledoc """
  Makes `usage_events.task_id` nullable and adds a `source` discriminator
  (bd-adyhvn).

  The ledger could only record spend that belongs to a task, so everything
  else Arbiter spends — the per-workspace quota `RefreshProbe`, the per-dispatch
  auth pre-flight, and (next) coordinator / terminal sessions — was invisible.
  Each of those callers has no task, and a synthetic sentinel `task_id` (the
  pattern `Arbiter.Loop.Corpus` used for its `loop-analyze` rows) pollutes every
  task-grouped rollup with phantom tasks.

  `source` is one of `task | probe | preflight | coordinator_session |
  terminal_session | maintenance`. The values are deliberately
  **provider-agnostic** — they name the kind of caller, not the vendor — so the
  same set describes a codex or gemini probe without a new value.

  The column is deliberately plain `TEXT` with **no `CHECK` constraint**: the
  enumeration is enforced at the resource layer (`Arbiter.Usage.Event`'s
  `one_of` constraint), so adding a seventh source later is a one-line change
  and needs no migration at all. A DB-level enum would have cost a second
  table rebuild for every new caller, and buys nothing that the resource
  constraint doesn't already give us — every writer goes through Ash.

  ## Backfill

    * every existing row → `source = 'task'`;
    * the `loop-analyze` sentinel rows → `source = 'maintenance'` with
      `task_id` (and `base_task_id`) cleared, so `--by task` stops showing a
      task that never existed.

  ## Why a table rebuild

  SQLite has no `ALTER COLUMN`, and ecto_sqlite3 raises on `modify`. Dropping
  `NOT NULL` from `task_id` therefore means the standard 12-step rebuild:
  create the new shape, copy, drop, rename, recreate indexes. The column list
  below is `usage_events` as of this migration.
  """

  use Ecto.Migration

  @columns ~w(
    id task_id workspace_id repo step model provider tokens_in tokens_out
    cache_creation_tokens cache_read_tokens cost_usd cost_note duration_ms
    exit_status worker_run_id session_id occurred_at raw base_task_id role
    inserted_at updated_at
  )

  def up do
    execute("""
    CREATE TABLE "usage_events_migration_new" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "task_id" TEXT,
      "source" TEXT NOT NULL DEFAULT 'task',
      "workspace_id" TEXT,
      "repo" TEXT,
      "step" TEXT NOT NULL,
      "model" TEXT,
      "provider" TEXT,
      "tokens_in" INTEGER,
      "tokens_out" INTEGER,
      "cache_creation_tokens" INTEGER,
      "cache_read_tokens" INTEGER,
      "cost_usd" NUMERIC,
      "cost_note" TEXT,
      "duration_ms" INTEGER,
      "exit_status" INTEGER,
      "worker_run_id" TEXT,
      "session_id" TEXT,
      "occurred_at" TEXT NOT NULL,
      "raw" TEXT,
      "base_task_id" TEXT,
      "role" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "usage_events_migration_new" (#{quoted(@columns)}, "source")
    SELECT
      "id",
      CASE WHEN "task_id" = 'loop-analyze' THEN NULL ELSE "task_id" END,
      "workspace_id", "repo", "step", "model", "provider", "tokens_in",
      "tokens_out", "cache_creation_tokens", "cache_read_tokens", "cost_usd",
      "cost_note", "duration_ms", "exit_status", "worker_run_id", "session_id",
      "occurred_at", "raw",
      CASE WHEN "base_task_id" = 'loop-analyze' THEN NULL ELSE "base_task_id" END,
      "role", "inserted_at", "updated_at",
      CASE WHEN "task_id" = 'loop-analyze' THEN 'maintenance' ELSE 'task' END
    FROM "usage_events"
    """)

    execute(~s[DROP TABLE "usage_events"])
    execute(~s[ALTER TABLE "usage_events_migration_new" RENAME TO "usage_events"])

    create index(:usage_events, [:workspace_id, :occurred_at])
    create index(:usage_events, [:task_id, :occurred_at])
    create index(:usage_events, [:worker_run_id])
    create index(:usage_events, [:base_task_id, :occurred_at])
    create index(:usage_events, [:source, :occurred_at])
  end

  def down do
    # Rolling back reinstates NOT NULL, so task-less rows need *some* task id.
    # They get their source name back as the sentinel they would have had to
    # use before this migration — no row is deleted.
    execute("""
    CREATE TABLE "usage_events_migration_old" (
      "id" TEXT NOT NULL PRIMARY KEY,
      "task_id" TEXT NOT NULL,
      "workspace_id" TEXT,
      "repo" TEXT,
      "step" TEXT NOT NULL,
      "model" TEXT,
      "provider" TEXT,
      "tokens_in" INTEGER,
      "tokens_out" INTEGER,
      "cache_creation_tokens" INTEGER,
      "cache_read_tokens" INTEGER,
      "cost_usd" NUMERIC,
      "cost_note" TEXT,
      "duration_ms" INTEGER,
      "exit_status" INTEGER,
      "worker_run_id" TEXT,
      "session_id" TEXT,
      "occurred_at" TEXT NOT NULL,
      "raw" TEXT,
      "base_task_id" TEXT,
      "role" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "usage_events_migration_old" (#{quoted(@columns)})
    SELECT
      "id",
      COALESCE("task_id", CASE WHEN "source" = 'maintenance' THEN 'loop-analyze' ELSE "source" END),
      "workspace_id", "repo", "step", "model", "provider", "tokens_in",
      "tokens_out", "cache_creation_tokens", "cache_read_tokens", "cost_usd",
      "cost_note", "duration_ms", "exit_status", "worker_run_id", "session_id",
      "occurred_at", "raw", "base_task_id", "role", "inserted_at", "updated_at"
    FROM "usage_events"
    """)

    execute(~s[DROP TABLE "usage_events"])
    execute(~s[ALTER TABLE "usage_events_migration_old" RENAME TO "usage_events"])

    create index(:usage_events, [:workspace_id, :occurred_at])
    create index(:usage_events, [:task_id, :occurred_at])
    create index(:usage_events, [:worker_run_id])
    create index(:usage_events, [:base_task_id, :occurred_at])
  end

  defp quoted(columns), do: Enum.map_join(columns, ", ", &~s["#{&1}"])
end
