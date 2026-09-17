defmodule Arbiter.Repo.Migrations.DropAssigneeFromIssues do
  @moduledoc """
  bd-1ozks5: drops the local `issues.assignee` column. Arbiter is a local
  single-user app; the column has no behavioral consumer (its only reader,
  the board's mine/all toggle, was removed in bd-2xc5lq) and is nil on every
  row of the operator's dev install.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      remove(:assignee)
    end
  end

  def down do
    alter table(:issues) do
      add(:assignee, :text)
    end
  end
end
