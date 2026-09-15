defmodule Arbiter.MCP.TaskEstimateTest do
  @moduledoc """
  bd-3j4ch4 AC5: `task_show` carries the cost estimate, so a coordinator
  sizing work sees the range without a second tool call.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp workspace! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-estimate-#{System.unique_integer([:positive])}",
        prefix: "mce"
      })

    ws
  end

  defp closed_task_costing!(ws, cost) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "history",
        workspace_id: ws.id,
        difficulty: 2,
        issue_type: :feature
      })

    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)

    {:ok, _ev} =
      Ash.create(Event, %{
        task_id: closed.id,
        base_task_id: closed.id,
        role: "base",
        source: :task,
        step: :work,
        workspace_id: ws.id,
        cost_usd: cost,
        occurred_at: DateTime.utc_now()
      })

    closed
  end

  describe "with enough history" do
    setup do
      ws = workspace!()

      # Ten closed D2 features at $1..$10 — one clean (difficulty, issue_type)
      # rung, whose nearest-rank p25/median/p75/p90 are $3 / $5 / $8 / $9.
      Enum.each(1..10, &closed_task_costing!(ws, &1 * 1.0))

      {:ok, task} =
        Ash.create(Issue, %{
          title: "the task being sized",
          workspace_id: ws.id,
          difficulty: 2,
          issue_type: :feature
        })

      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
      worker = %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id}

      {:ok, ws: ws, task: task, coordinator: coordinator, worker: worker}
    end

    test "the slim task_show view carries the estimate", ctx do
      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id})

      assert %{
               range: [3.0, 8.0],
               median: 5.0,
               p90: 9.0,
               n: 10,
               basis: "difficulty+type",
               fallback_level: 0
             } = data.estimate
    end

    test "the full task_show view carries the estimate too", ctx do
      assert {:ok, data} =
               Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})

      assert data.estimate.median == 5.0
    end

    test "a worker reading its own task sees the estimate", ctx do
      assert {:ok, data} = Tools.task_show(ctx.worker, %{})
      assert data.estimate.n == 10
    end
  end

  describe "with no history" do
    test "the estimate is nil, not absent, so the field is never mistaken for $0" do
      ws = workspace!()
      {:ok, task} = Ash.create(Issue, %{title: "no history", workspace_id: ws.id})

      scope = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      assert {:ok, data} = Tools.task_show(scope, %{"id" => task.id})
      assert Map.has_key?(data, :estimate)
      assert data.estimate == nil
    end
  end
end
