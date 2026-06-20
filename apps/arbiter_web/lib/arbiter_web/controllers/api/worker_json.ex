defmodule ArbiterWeb.Api.WorkerJSON do
  alias Arbiter.Workers.Run
  alias ArbiterWeb.Api.IssueJSON

  def dispatch(%{result: result}) do
    %{
      task: IssueJSON.data(result.task),
      worker: %{
        task_id: result.task.id,
        pid: inspect(result.worker_pid)
      },
      machine: %{
        id: result.machine_id,
        pid: inspect(result.machine_pid)
      },
      worktree_path: Map.get(result, :worktree_path),
      claude_started: not is_nil(Map.get(result, :claude_port))
    }
  end

  def index(%{children: children, costs: costs}) do
    %{
      data:
        Enum.map(children, fn snap ->
          meta = Map.get(snap, :meta, %{}) || %{}
          model_id = Map.get(meta, :model) || get_in(meta, [:routing_config, :model])

          %{
            task_id: snap.task_id,
            workspace_id: snap.workspace_id,
            repo: snap.repo,
            current_step: snap.current_step,
            claude_session: Map.get(meta, :claude_session, false),
            activity: Map.get(meta, :activity),
            status: snap.status,
            started_at: snap.started_at,
            mr_ref: Map.get(snap, :mr_ref),
            merger_url: Map.get(snap, :merger_url),
            pid: inspect(snap.pid),
            model: Arbiter.Worker.Stats.short_model_name(model_id),
            cost_usd: Map.get(costs, snap.task_id, 0.0)
          }
        end)
    }
  end

  def show(%{snapshot: snap}) do
    meta = Map.get(snap, :meta, %{})

    %{
      source: "live",
      task_id: snap.task_id,
      workspace_id: snap.workspace_id,
      repo: snap.repo,
      current_step: snap.current_step,
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      status: snap.status,
      started_at: snap.started_at,
      step_started_at: Map.get(snap, :step_started_at),
      mr_ref: Map.get(snap, :mr_ref),
      merger_url: Map.get(snap, :merger_url),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: Map.get(meta, :last_checked_at),
      pid: inspect(snap.pid),
      output_lines: Map.get(meta, :output_lines, []),
      exit_status: Map.get(meta, :exit_status),
      exited_at: Map.get(meta, :exited_at),
      result: Map.get(meta, :result),
      failure_reason: stringify(Map.get(meta, :failure_reason))
    }
  end

  # Historical fallback: no live worker, so we render the most recent durable
  # `Run` row into the same shape the CLI's `worker show` already knows how to
  # display. `source: "history"` lets clients flag that this is a post-mortem
  # rather than a live snapshot.
  def show(%{run: %Run{} = run}) do
    %{
      source: "history",
      task_id: run.task_id,
      task_title: run.task_title,
      workspace_id: run.workspace_id,
      repo: run.repo,
      current_step: nil,
      claude_session: false,
      activity: nil,
      status: to_string_atom(run.status),
      started_at: run.started_at,
      completed_at: run.completed_at,
      exit_status: run.exit_code,
      output_lines: run.output_lines || [],
      failure_reason: run.failure_reason
    }
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s
end
