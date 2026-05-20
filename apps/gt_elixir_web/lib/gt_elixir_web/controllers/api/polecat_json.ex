defmodule GtElixirWeb.Api.PolecatJSON do
  alias GtElixirWeb.Api.IssueJSON

  def sling(%{result: result}) do
    %{
      bead: IssueJSON.data(result.bead),
      polecat: %{
        bead_id: result.bead.id,
        pid: inspect(result.polecat_pid)
      },
      machine: %{
        id: result.machine_id,
        pid: inspect(result.machine_pid)
      },
      worktree_path: Map.get(result, :worktree_path),
      claude_started: not is_nil(Map.get(result, :claude_port))
    }
  end

  def index(%{children: children}) do
    %{
      data:
        Enum.map(children, fn snap ->
          %{
            bead_id: snap.bead_id,
            workspace_id: snap.workspace_id,
            rig: snap.rig,
            current_step: snap.current_step,
            status: snap.status,
            started_at: snap.started_at,
            pid: inspect(snap.pid)
          }
        end)
    }
  end

  def show(%{snapshot: snap}) do
    meta = Map.get(snap, :meta, %{})

    %{
      bead_id: snap.bead_id,
      workspace_id: snap.workspace_id,
      rig: snap.rig,
      current_step: snap.current_step,
      status: snap.status,
      started_at: snap.started_at,
      step_started_at: Map.get(snap, :step_started_at),
      pid: inspect(snap.pid),
      output_lines: Map.get(meta, :output_lines, []),
      exit_status: Map.get(meta, :exit_status),
      exited_at: Map.get(meta, :exited_at),
      result: Map.get(meta, :result),
      failure_reason: stringify(Map.get(meta, :failure_reason))
    }
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
