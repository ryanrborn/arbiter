defmodule Arbiter.Workflows.MachineState do
  @moduledoc """
  Persistent state for a single `Arbiter.Workflows.Machine` instance.

  Each row binds a `Arbiter.Workflow` behaviour module to a task (issue),
  along with the threaded state passed between `run_step/2` calls. The row
  is updated on every transition so a crashed machine can resume by
  re-reading its row.

  ## Module name persistence

  `workflow_module` is stored as a string (e.g. `"Elixir.Arbiter.Workflow.Example.GreetThenWave"`)
  and reconstituted at load via `Module.safe_concat/1`. The reconstituted
  atom is then validated to ensure it implements the `Arbiter.Workflow`
  behaviour before any of its functions are invoked. See
  `Arbiter.Workflows.Machine.load_workflow_module/1` for the allowlist
  check.

  ## Status FSM (mirrors the FSM "state" in `Machine`)

      :idle  ──start──► :running  ──advance──► :running
                            │                       │
                            │ all done              │ {:error, _}
                            ▼                       ▼
                       :completed                 :failed
                            ▲                       ▲
                            │                       │
                            └─ pause ⇄ resume ──────┘
                                  (:paused)

  ## Task ↔ workflow_module cardinality

  **1-to-many on a task.** A single task may have multiple machines bound to
  it over time (different workflows applied sequentially, or one re-run
  after failure). Each is a distinct row with a unique `id`. We do not
  enforce a uniqueness constraint on `(task_id, workflow_module)`; the
  caller decides whether to re-attach or resume.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workflows,
    data_layer: AshSqlite.DataLayer

  @statuses ~w(idle running paused completed failed)a

  sqlite do
    table "workflow_machine_states"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :workflow_module,
        :task_id,
        :vars,
        :current_step,
        :status,
        :completed_steps,
        :state,
        :error_reason
      ]
    end

    update :update do
      primary? true

      accept [
        :current_step,
        :status,
        :completed_steps,
        :state,
        :error_reason
      ]

      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :workflow_module, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
      description "Fully-qualified module name. Re-hydrated via Module.safe_concat/1."
    end

    attribute :task_id, :string do
      allow_nil? false
      public? true

      description "Issue id this machine is bound to. Not an Ash relationship to avoid coupling the Workflows domain to Tasks — the Machine reads tasks at runtime when needed."
    end

    attribute :vars, :map do
      public? true
      default %{}
      description "Workflow's vars/0 keys populated at attach time."
    end

    attribute :current_step, :string do
      allow_nil? false
      public? true
      default "__pending__"

      description "Atom name of the step that will be executed by the next advance/1. Stored as a string; converted via String.to_existing_atom/1 after the workflow module is loaded."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :idle
      constraints one_of: @statuses
    end

    attribute :completed_steps, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "List of step atom names already completed, in execution order."
    end

    attribute :state, :map do
      allow_nil? false
      public? true
      default %{}
      description "The threaded state passed to run_step/2."
    end

    attribute :error_reason, :string do
      public? true
      description "inspect/1'd error from a failing run_step/2. Populated when status is :failed."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  @doc "List of valid status atoms."
  def statuses, do: @statuses
end
