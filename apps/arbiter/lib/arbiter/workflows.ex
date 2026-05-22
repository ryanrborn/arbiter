defmodule Arbiter.Workflows do
  @moduledoc """
  Ash domain for workflow execution state.

  Holds the persistent state machine rows that drive
  `Arbiter.Workflow` modules step-by-step against beads (gte-015).

  This is a sibling of `Arbiter.Beads` rather than a member because
  workflows are not beads — they are *driven by* beads. Keeping the domains
  separate avoids polluting the bead ledger with execution scaffolding.

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
