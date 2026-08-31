defmodule Arbiter.Repo.Migrations.AddRepoToIssues do
  @moduledoc """
  Adds `issues.repo` — the repo an issue belongs to (bd-2jum8j).

  Until now a repo was purely a per-dispatch opt: nothing persisted which repo
  an issue was *for*, so in a multi-repo workspace every dispatch — manual or
  Autopilot-driven — had to pass `repo:` explicitly or die with
  `{:ambiguous_repo, _}`. This column lets the assignment be made once, on the
  issue, and stick.

  Nullable with no default and no backfill: the overwhelming majority of
  workspaces are single-repo, where dispatch already auto-selects the sole
  configured repo. `NULL` means "unassigned" and preserves exactly the old
  resolution behaviour for every existing row.

  Hand-written: this repo's `priv/resource_snapshots/` are stale enough that
  `mix ash_sqlite.generate_migrations` emits a large destructive diff.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :repo, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :repo
    end
  end
end
