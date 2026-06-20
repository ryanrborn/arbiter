defmodule Arbiter.Workflows do
  @moduledoc """
  Ash domain for workflow execution state.

  Holds the persistent state machine rows that drive
  `Arbiter.Workflow` modules step-by-step against tasks (gte-015).

  This is a sibling of `Arbiter.Tasks` rather than a member because
  workflows are not tasks — they are *driven by* tasks. Keeping the domains
  separate avoids polluting the task ledger with execution scaffolding.

  Resources:

    * `Arbiter.Workflows.MachineState` — gte-015 — persistent state for a
      single workflow instance (current step, threaded state, completed
      steps, status).
  """

  use Ash.Domain

  resources do
    resource Arbiter.Workflows.MachineState
  end
end
