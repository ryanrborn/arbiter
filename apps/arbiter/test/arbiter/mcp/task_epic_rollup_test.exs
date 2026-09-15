defmodule Arbiter.MCP.TaskEpicRollupTest do
  @moduledoc """
  bd-18vl9q AC3: `task_show` carries the epic cost rollup for an `:epic`
  issue, and `nil` for anything else — mirrors `task_estimate_test.exs`.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp workspace! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-epic-rollup-#{System.unique_integer([:positive])}",
        prefix: "mer"
      })

    ws
  end

  test "task_show carries the epic cost rollup for an epic" do
    ws = workspace!()

    {:ok, epic} = Ash.create(Issue, %{title: "an epic", workspace_id: ws.id, issue_type: :epic})

    {:ok, child} =
      Ash.create(Issue, %{title: "a child", workspace_id: ws.id, issue_type: :task})

    {:ok, closed} = Ash.update(child, %{close_upstream: false}, action: :close)

    {:ok, _ev} =
      Ash.create(Event, %{
        task_id: closed.id,
        base_task_id: closed.id,
        role: "base",
        source: :task,
        step: :work,
        workspace_id: ws.id,
        cost_usd: 4.25,
        occurred_at: DateTime.utc_now()
      })

    {:ok, _} = Dependencies.add(epic.id, closed.id, :parent_of)

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    assert {:ok, data} = Tools.task_show(coordinator, %{"id" => epic.id})

    assert %{spent: 4.25, closed_count: 1} = data.epic_rollup
  end

  test "task_show's epic rollup is nil for a non-epic issue" do
    ws = workspace!()
    {:ok, task} = Ash.create(Issue, %{title: "not an epic", workspace_id: ws.id})

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    assert {:ok, data} = Tools.task_show(coordinator, %{"id" => task.id})
    assert Map.has_key?(data, :epic_rollup)
    assert data.epic_rollup == nil
  end
end
