defmodule GtElixir.Workflows.Work do
  @moduledoc """
  The default polecat work workflow. Port of `mol-polecat-work` from the Go
  Gas Town.

  Steps: `:load_context`, `:design`, `:implement`, `:pre_verify`, `:submit`.

  ## Tracker polymorphism

  The `:submit` step is tracker-polymorphic. It reads the bead's
  `tracker_type` and dispatches through `GtElixir.Trackers.transition/2`:

    * `:none`  — no-op (no external tracker to notify).
    * `:jira`  — transitions to the workspace-configured "done" name
                 (default `"Code Complete"` per the Verus convention).
    * `:linear`, `:github` — Phase 5; will dispatch through their adapters
                 when those land.

  This module contains **no Jira-specific code**. All tracker semantics live
  in the adapter modules.

  ## State shape

  `run/2` (via `GtElixir.Workflow.run/2`) threads a state map through each
  step. Required input vars (the state must include these at start):

    * `:bead_id` — string. The bead this polecat is working on.
    * `:worktree_path` — string. Where the branch lives.
    * `:rig` — string. The repo / project key.

  Each step appends `:<step>_done` to the state for downstream steps to
  inspect; `:submit_result` carries the Trackers.transition return.
  """

  use GtElixir.Workflow,
    steps: [:load_context, :design, :implement, :pre_verify, :submit]

  alias GtElixir.Beads.Issue
  alias GtElixir.Trackers

  step :load_context,
    description: "Load the bead + acceptance criteria into state",
    needs: [],
    vars: [:bead_id, :worktree_path, :rig]

  step :design,
    description: "Sketch the implementation plan",
    needs: [:load_context],
    vars: []

  step :implement,
    description: "Write code + tests",
    needs: [:design],
    vars: []

  step :pre_verify,
    description: "Run tests + linters in the worktree",
    needs: [:implement],
    vars: []

  step :submit,
    description: "Transition the bead via its tracker adapter",
    needs: [:pre_verify],
    vars: []

  @impl true
  def run_step(:load_context, %{bead_id: bead_id} = state) do
    case Ash.get(Issue, bead_id) do
      {:ok, issue} ->
        {:ok, Map.put(state, :bead, issue)}

      {:error, _} = err ->
        err
    end
  end

  def run_step(:design, state) do
    # Phase 2: placeholder. Real design work happens inside the polecat's
    # Claude session, not here. This step exists so the workflow graph is
    # complete and downstream steps' needs: are satisfied.
    {:ok, Map.put(state, :design_done, true)}
  end

  def run_step(:implement, state) do
    {:ok, Map.put(state, :implement_done, true)}
  end

  def run_step(:pre_verify, state) do
    {:ok, Map.put(state, :pre_verify_done, true)}
  end

  def run_step(:submit, %{bead: %Issue{} = bead} = state) do
    # Polymorphic dispatch via the bead's tracker. None-tracked beads no-op
    # silently; Jira/Linear/GitHub beads call out through their adapter.
    # Trackers.transition raises ArgumentError for unregistered types (e.g.
    # :linear pre-Phase-5); we let that propagate so misconfigured beads
    # surface loudly rather than silently failing to notify.
    case safe_transition(bead) do
      :ok ->
        {:ok, Map.put(state, :submit_result, :ok)}

      {:error, reason} = err ->
        {:error,
         Map.put(state, :submit_result, {:error, reason})
         |> Map.put(:error_reason, reason)}
        # ^^ workflow runner treats this as failed; reason propagates up
        err
    end
  end

  def run_step(:submit, state) do
    # If :load_context didn't store the bead (shouldn't happen given needs:
    # but be defensive), fall through with a clear error.
    {:error, {:missing_bead, state}}
  end

  defp safe_transition(%Issue{tracker_type: :none}), do: :ok
  defp safe_transition(%Issue{} = bead), do: Trackers.transition(bead, :closed)
end
