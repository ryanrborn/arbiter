defmodule Arbiter.Repo.Migrations.AddAcceptanceWaivedToIssues do
  @moduledoc """
  Adds `acceptance_waived` to `issues` (bd-7mbrlg).

  Nullable, no default, no backfill — safe to hot-run against a live
  database. Existing issues start with no waiver on file, which is exactly
  today's behaviour (the `:promote_to_ready` guard treats an already-refined
  issue as grandfathered regardless of this field).
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :acceptance_waived, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :acceptance_waived
    end
  end
end
