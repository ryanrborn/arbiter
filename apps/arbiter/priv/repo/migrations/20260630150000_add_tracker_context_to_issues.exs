defmodule Arbiter.Repo.Migrations.AddTrackerContextToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :tracker_context_type, :text, null: true
      add :tracker_context_ref, :text, null: true
    end
  end
end
