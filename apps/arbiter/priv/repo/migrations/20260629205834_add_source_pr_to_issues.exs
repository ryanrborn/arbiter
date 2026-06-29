defmodule Arbiter.Repo.Migrations.AddSourcePrToIssues do
  @moduledoc """
  Adds the `source_pr` column to `issues` (bd-ci2jl2).

  PRPatrol follow-up tasks record the PR they were filed against so a second
  follow-up isn't filed for the same PR (dedup). That linkage used to overload
  `tracker_ref`, which is *also* the tracker-lifecycle write-back target — so
  dispatching a follow-up tried to transition a merged PR and failed with
  `Validation Failed`. The dedup linkage now lives in its own `source_pr`
  column, and follow-ups carry `tracker_type: :none` (no lifecycle write-back).

  Nullable text, matching the `tracker_ref` / `pr_ref` columns; only PRPatrol
  follow-ups populate it.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :source_pr, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :source_pr
    end
  end
end
