defmodule Arbiter.Repo.Migrations.AddPendingMergeToIssues do
  @moduledoc """
  Adds the durable pending-merge stamp to `issues` (bd-a370ak / #2002).

  One nullable JSON column, no default and no backfill — safe to hot-run
  against the live database. Every existing issue starts with no pending
  merge, which is exactly today's behaviour. See `Arbiter.Mergers.PendingMerge`.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :pending_merge, :map
    end
  end

  def down do
    alter table(:issues) do
      remove :pending_merge
    end
  end
end
