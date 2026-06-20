defmodule Arbiter.Workflows.Work do
  @moduledoc """
  The default worker work workflow. Port of `mol-worker-work` from the Go
  Gas Town.

  Steps: `:load_context`, `:design`, `:implement`, `:pre_verify`, `:submit`.

  ## Tracker polymorphism

  The `:submit` step is tracker-polymorphic. It reads the task's
  `tracker_type` and dispatches through `Arbiter.Trackers.transition/2`:

    * `:none`  — no-op (no external tracker to notify).
    * `:jira`  — transitions to the workspace-configured "done" name
                 (default `"Code Complete"` per the Verus convention).
    * `:linear`, `:github` — Phase 5; will dispatch through their adapters
                 when those land.

  This module contains **no Jira-specific code**. All tracker semantics live
  in the adapter modules.

  ## State shape

  `run/2` (via `Arbiter.Workflow.run/2`) threads a state map through each
  step. Required input vars (the state must include these at start):

    * `:task_id` — string. The task this worker is working on.
    * `:worktree_path` — string. Where the branch lives.
    * `:repo` — string. The repo / project key.

  Each step appends `:<step>_done` to the state for downstream steps to
  inspect; `:submit_result` carries the Trackers.transition return.

  ## Mailbox convention

  Workers coordinate through the inter-agent message queue
  (`Arbiter.Messages.Message`), not tmux prompt injection. By **convention**
  (not enforced by the Driver), an worker checks its mailbox at the start of
  each workflow step by running:

      arb inbox <task-id>

  This surfaces any unread direction from the Admiral (`arb message <task-id>
  <text>`) or flags from sibling workers, and marks them read. The Driver
  does not poll the mailbox — it is the worker's responsibility via the CLI.
  See `Arbiter.Worker.Dispatch.prompt_for/1` for where this is wired into the
  Claude prompt template.
  """

  use Arbiter.Workflow,
    steps: [:load_context, :design, :implement, :pre_verify, :submit]

  alias Arbiter.Tasks.Issue
  alias Arbiter.Trackers

  step(:load_context,
    description: "Load the task + acceptance criteria into state",
    needs: [],
    vars: [:task_id, :worktree_path, :repo]
  )

  step(:design,
    description: "Sketch the implementation plan",
    needs: [:load_context],
    vars: []
  )

  step(:implement,
    description: "Write code + tests",
    needs: [:design],
    vars: []
  )

  step(:pre_verify,
    description: "Run tests + linters in the worktree",
    needs: [:implement],
    vars: []
  )

  step(:submit,
    description: "Transition the task via its tracker adapter",
    needs: [:pre_verify],
    vars: []
  )

  @impl true
  def run_step(:load_context, state) do
    case fetch_var(state, :task_id) do
      {:ok, task_id} ->
        case Ash.get(Issue, task_id) do
          {:ok, %Issue{}} ->
            # Don't put the struct into state — `Workflows.Machine`
            # JSON-encodes state on every persist, and Ash structs aren't
            # Jason-serializable. Just record that we successfully loaded;
            # `:submit` re-fetches.
            {:ok, Map.put(state, :load_context_done, true)}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, {:missing_var, :task_id}}
    end
  end

  def run_step(:design, state) do
    # Phase 2: placeholder. Real design work happens inside the worker's
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

  def run_step(:submit, state) do
    # Re-fetch the task by id rather than reading a struct from state
    # (state is JSON-roundtripped between steps; structs don't survive).
    case fetch_var(state, :task_id) do
      {:ok, task_id} ->
        case Ash.get(Issue, task_id) do
          {:ok, %Issue{} = task} ->
            case safe_transition(task) do
              :ok ->
                {:ok, Map.put(state, :submit_result, :ok)}

              {:error, reason} = err ->
                _ =
                  state
                  |> Map.put(:submit_result, {:error, reason})
                  |> Map.put(:error_reason, reason)

                err
            end

          {:error, _} ->
            {:error, {:task_not_found, task_id}}
        end

      :error ->
        {:error, {:missing_var, :task_id}}
    end
  end

  defp safe_transition(%Issue{tracker_type: :none}), do: :ok
  defp safe_transition(%Issue{} = task), do: Trackers.transition(task, :closed)

  # Tolerate both atom-keyed (direct test callers) and string-keyed
  # (`Workflows.Machine` after JSON roundtrip) state maps.
  defp fetch_var(state, key) when is_atom(key) do
    case Map.fetch(state, key) do
      {:ok, val} -> {:ok, val}
      :error -> Map.fetch(state, Atom.to_string(key))
    end
  end
end
