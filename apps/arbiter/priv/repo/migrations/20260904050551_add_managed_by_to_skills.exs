defmodule Arbiter.Repo.Migrations.AddManagedByToSkills do
  @moduledoc """
  Adds `skills.managed_by` (bd-blxwla): who *authored* a skill
  (`operator` / `loop` / `unknown`), distinct from the existing `actor`
  column (who made the most recent write).

  This must exist before the first loop-authored skill lands (#1011 comment
  5224098209 §5) — once `Arbiter.Loop.Apply` starts writing skill bodies
  without this flag, there is no way to reconstruct after the fact which
  registry rows are machine-authored.

  Backfill: every skill in the registry today predates loop
  payload-authoring (the three seeded skills date to 2026-07-06, and nothing
  else has ever set `body`/`metadata` outside a human/coordinator path), so
  all existing rows backfill to `operator`. `unknown` is reserved for
  provenance that genuinely can't be established going forward; the backfill
  here leaves zero such rows.

  Hand-written, like `20260824170000_add_refined_to_issues.exs` before it:
  this repo's `priv/resource_snapshots/` are stale enough that
  `mix ash_sqlite.generate_migrations` emits a large unrelated diff.
  """

  use Ecto.Migration

  def up do
    alter table(:skills) do
      add :managed_by, :text, default: "operator"
    end

    execute("UPDATE skills SET managed_by = 'operator' WHERE managed_by IS NULL")
  end

  def down do
    alter table(:skills) do
      remove :managed_by
    end
  end
end
