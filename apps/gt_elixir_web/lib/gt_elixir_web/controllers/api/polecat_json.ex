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
      }
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
end
