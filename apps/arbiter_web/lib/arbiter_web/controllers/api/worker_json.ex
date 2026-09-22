defmodule ArbiterWeb.Api.WorkerJSON do
  alias Arbiter.Usage.LiveSpend
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
      # bd-aw2cyt: a row's phase depends on the task's other live rounds, so
      # stamp it over the whole list first.
      data:
        children
        |> Arbiter.Worker.Phase.annotate()
        |> Enum.map(fn snap ->
          meta = Map.get(snap, :meta, %{}) || %{}
          model_id = Map.get(meta, :model) || get_in(meta, [:routing_config, :model])

          %{
            task_id: snap.task_id,
            # bd-8lq2g7: a task can have two live rows — its primary worker plus
            # a merge-queue subordinate pass under `<task_id>:fixpass` /
            # `:conflict`. These two fields are what tell them apart.
            registry_key: Map.get(snap, :registry_key) || snap.task_id,
            role: to_string_atom(Map.get(snap, :role)),
            workspace_id: snap.workspace_id,
            repo: snap.repo,
            current_step: snap.current_step,
            claude_session: Map.get(meta, :claude_session, false),
            activity: Map.get(meta, :activity),
            status: snap.status,
            # bd-aw2cyt: additive — `status` keeps its meaning for every
            # existing consumer, and these two say whether a process exists.
            phase: phase(snap),
            phase_label: Arbiter.Worker.Phase.label(Map.get(snap, :phase)),
            agent_live: Map.get(snap, :agent_live),
            started_at: snap.started_at,
            mr_ref: Map.get(snap, :mr_ref),
            merger_url: Map.get(snap, :merger_url),
            pid: inspect(snap.pid),
            model: Arbiter.Worker.Stats.short_model_name(model_id)
          }
          # bd-8vnuy3: settled + in-flight; `cost_usd: nil` means n/a.
          |> Map.merge(LiveSpend.cost_fields(Map.get(costs, snap.task_id)))
        end)
    }
  end

  def show(%{snapshot: snap} = assigns) do
    meta = Map.get(snap, :meta, %{})

    %{
      source: "live",
      task_id: snap.task_id,
      # See index/1 — a subordinate pass shares the task's id (bd-8lq2g7).
      registry_key: Map.get(snap, :registry_key) || snap.task_id,
      role: to_string_atom(Map.get(snap, :role)),
      workspace_id: snap.workspace_id,
      repo: snap.repo,
      current_step: snap.current_step,
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      status: snap.status,
      # See index/1 — additive alongside the unchanged status (bd-aw2cyt).
      phase: phase(snap),
      phase_label: Arbiter.Worker.Phase.label(Map.get(snap, :phase)),
      agent_live: Map.get(snap, :agent_live),
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
    |> Map.merge(LiveSpend.cost_fields(Map.get(assigns, :cost)))
  end

  # Historical fallback: no live worker, so we render the most recent durable
  # `Run` row into the same shape the CLI's `worker show` already knows how to
  # display. `source: "history"` lets clients flag that this is a post-mortem
  # rather than a live snapshot.
  def show(%{run: %Run{} = run} = assigns) do
    %{
      source: "history",
      task_id: run.task_id,
      task_title: run.task_title,
      workspace_id: run.workspace_id,
      repo: run.repo,
      worker_type: to_string_atom(run.worker_type),
      current_step: nil,
      claude_session: false,
      activity: nil,
      status: to_string_atom(run.status),
      model: run.model,
      started_at: run.started_at,
      completed_at: run.completed_at,
      exit_status: run.exit_code,
      output_lines: run.output_lines || [],
      failure_reason: run.failure_reason
    }
    |> Map.merge(LiveSpend.cost_fields(Map.get(assigns, :cost)))
  end

  defp phase(snap), do: to_string_atom(Map.get(snap, :phase))

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s
end
