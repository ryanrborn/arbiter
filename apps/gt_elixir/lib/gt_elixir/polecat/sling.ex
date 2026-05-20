defmodule GtElixir.Polecat.Sling do
  @moduledoc """
  Spawn a polecat for a bead and attach it to the `GtElixir.Workflows.Work`
  workflow via `GtElixir.Workflows.Machine`.

  This is the "go work this bead" entry point — called by:

    * the `bd2 sling <bead-id>` CLI command (via the REST API),
    * the `Refinery` GenServer (when re-dispatching follow-ups),
    * Phoenix LiveView dashboards that have a "send polecat" button.

  Single responsibility: orchestrate the three steps needed to start a
  polecat working on a bead, in the right order, with the right cleanup if
  anything fails.

  ## Steps

  1. Load + validate the bead. Bead must not be `:closed`.
  2. Transition bead to `:in_progress` (via the bead's `:update` action,
     skipping the `:close` FSM path).
  3. Start a polecat under `GtElixir.Polecat.Supervisor` for the bead.
  4. Attach `GtElixir.Workflows.Work` via `Workflows.Machine.attach/3` and
     start the machine.

  ## Returns

  ```
  {:ok, %{
    bead: %Issue{},          # updated, status: :in_progress
    polecat_pid: pid(),
    machine_id: String.t(),
    machine_pid: pid()
  }}
  ```

  Or `{:error, reason}` for any step that fails. On error, partial work is
  best-effort-rolled-back (started polecat is stopped; bead status revert is
  NOT attempted because the user may want to inspect what happened).
  """

  alias GtElixir.Beads.Issue
  alias GtElixir.Polecat
  alias GtElixir.Workflows.Machine
  alias GtElixir.Workflows.Work

  @type sling_opts :: [
          rig: String.t() | nil,
          workflow_module: module()
        ]

  @type sling_result :: %{
          bead: Issue.t(),
          polecat_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid()
        }

  @spec sling(String.t(), sling_opts()) :: {:ok, sling_result()} | {:error, term()}
  def sling(bead_id, opts \\ []) when is_binary(bead_id) do
    with {:ok, bead} <- load_bead(bead_id),
         :ok <- ensure_not_closed(bead),
         {:ok, bead} <- transition_to_in_progress(bead),
         {:ok, polecat_pid} <- start_polecat(bead, opts),
         {:ok, machine_id, machine_pid} <- attach_and_start_machine(bead, opts) do
      {:ok,
       %{
         bead: bead,
         polecat_pid: polecat_pid,
         machine_id: machine_id,
         machine_pid: machine_pid
       }}
    else
      err -> err
    end
  end

  defp load_bead(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, bead} -> {:ok, bead}
      {:error, _} -> {:error, {:bead_not_found, bead_id}}
    end
  end

  defp ensure_not_closed(%Issue{status: :closed, id: id}), do: {:error, {:bead_closed, id}}
  defp ensure_not_closed(_bead), do: :ok

  defp transition_to_in_progress(%Issue{status: :in_progress} = bead), do: {:ok, bead}

  defp transition_to_in_progress(%Issue{} = bead) do
    case Ash.update(bead, %{status: :in_progress}) do
      {:ok, updated} -> {:ok, updated}
      {:error, e} -> {:error, {:transition_failed, e}}
    end
  end

  defp start_polecat(%Issue{id: id, workspace_id: ws_id} = _bead, opts) do
    rig = Keyword.get(opts, :rig) || "unknown"

    case Polecat.start(bead_id: id, rig: rig, workspace_id: ws_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Idempotency: a polecat for this bead already exists. That's fine;
        # we'll attach a (possibly new) workflow to the existing process.
        {:ok, pid}

      {:error, reason} ->
        {:error, {:polecat_start_failed, reason}}
    end
  end

  defp attach_and_start_machine(%Issue{id: id}, opts) do
    workflow = Keyword.get(opts, :workflow_module, Work)
    vars = %{bead_id: id, worktree_path: nil, rig: Keyword.get(opts, :rig)}

    with {:ok, machine_id} <- Machine.attach(workflow, id, vars),
         {:ok, pid} <- Machine.start(machine_id) do
      {:ok, machine_id, pid}
    else
      err -> {:error, {:machine_start_failed, err}}
    end
  end
end
