defmodule ArbiterWeb.Api.WorkerPhaseTest do
  @moduledoc """
  bd-aw2cyt: `GET /api/workers` and `/api/workers/:task_id` — the JSON the
  `arb worker list` / `arb worker show` CLI renders — carry the worker's
  phase and whether its agent subprocess is live, alongside the unchanged
  `status`.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-phase-#{System.unique_integer([:positive])}",
        prefix: "apf#{System.unique_integer([:positive])}"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "api phase target", workspace_id: ws.id})

    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task.id, :normal) end)

    %{ws: ws, task: task, pid: pid}
  end

  test "index reports the phase and liveness next to the unchanged status", %{
    conn: conn,
    task: task
  } do
    body = conn |> get(~p"/api/workers") |> json_response(200)
    row = Enum.find(body["data"], &(&1["task_id"] == task.id))

    assert row["status"] == "running"
    assert row["agent_live"] == false
    # The record says running; nothing is actually running for it.
    refute row["phase"] == "implementing"
    assert is_binary(row["phase"])
    assert is_binary(row["phase_label"])
  end

  test "show reports the phase and liveness", %{conn: conn, task: task} do
    body = conn |> get(~p"/api/workers/#{task.id}") |> json_response(200)

    assert body["status"] == "running"
    assert body["agent_live"] == false
    assert is_binary(body["phase"])
    assert is_binary(body["phase_label"])
  end
end
