defmodule Arbiter.Repo.Migrations.AddRefinedToIssues do
  @moduledoc """
  Adds `issues.refined` — the board's Backlog/Ready split (bd-b5wyjd).

  `false` means "nobody has refined this yet": the card sits in the board's new
  Backlog column and the scheduler never considers it. `true` means it is
  dispatchable in principle and joins the Ready queue on the usual terms
  (priority, then age, minus whatever blocks it). This is deliberately not a
  status — the task FSM still only knows open/in_progress/closed — it is a
  derived-column input like a live worker or an open dependency.

  New rows default to `false`, because that is the point of the ticket: every
  creation path (`arb create`, `task_create`, the REST API, tracker sync, the
  dashboard form) now lands in Backlog until a human promotes it.

  Existing rows are backfilled to `true`. They were all created under the old
  semantics, where "created" *was* "ready", and defaulting them to `false`
  would silently empty the Ready queue on every install that runs this
  migration — stopping the autopilot dead and leaving the operator to promote
  a whole backlog's worth of already-triaged work by hand. Backfilling
  preserves the meaning those rows were written with; the new default only
  binds work created from here on.

  Hand-written: this repo's `priv/resource_snapshots/` are stale enough that
  `mix ash_sqlite.generate_migrations` emits a large destructive diff.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :refined, :boolean, default: false
    end

    # Every row that predates the column was "ready" by the old rules.
    execute("UPDATE issues SET refined = 1 WHERE refined IS NULL OR refined = 0")
  end

  def down do
    alter table(:issues) do
      remove :refined
    end
  end
end
