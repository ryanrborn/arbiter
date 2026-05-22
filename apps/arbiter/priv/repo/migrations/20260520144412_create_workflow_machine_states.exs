defmodule Arbiter.Repo.Migrations.CreateWorkflowMachineStates do
  @moduledoc """
  Adds the workflow_machine_states table — persistent state for
  `Arbiter.Workflows.Machine` instances (gte-015).
  """

  use Ecto.Migration

  def up do
    create table(:workflow_machine_states, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :workflow_module, :text, null: false
      add :bead_id, :text, null: false
      add :vars, :map, default: %{}
      add :current_step, :text, null: false, default: "__pending__"
      add :status, :text, null: false, default: "idle"
      add :completed_steps, {:array, :text}, null: false, default: []
      add :state, :map, null: false, default: %{}
      add :error_reason, :text

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:workflow_machine_states, [:bead_id])
    create index(:workflow_machine_states, [:status])
  end

  def down do
    drop table(:workflow_machine_states)
  end
end
