defmodule Arbiter.Repo.Migrations.AddCostNoteToUsageEvents do
  @moduledoc """
  Adds `cost_note` to `usage_events` (bd-2fzwlc).

  Cost derivation can legitimately fail (no priced model resolved, metered
  plan with no per-call dollar figure). Without this column a `nil` cost_usd
  is indistinguishable from a stream-parser bug silently dropping usage —
  `cost_note` records *why* so the row stays legible.
  """

  use Ecto.Migration

  def up do
    alter table(:usage_events) do
      add :cost_note, :text
    end
  end

  def down do
    alter table(:usage_events) do
      remove :cost_note
    end
  end
end
