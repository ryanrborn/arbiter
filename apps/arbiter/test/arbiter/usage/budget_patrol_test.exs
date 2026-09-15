defmodule Arbiter.Usage.BudgetPatrolTest do
  @moduledoc """
  The one-shot coordinator escalation raised when an open task's worker spend
  first crosses its estimate group's p90 (bd-8j9i9p AC5, operator decision
  2026-09-15).

  It informs; it does not intervene. Nothing here stops a worker, pauses
  anything or trips the circuit breaker — the point is that the coordinator
  gets to say whether the overrun is expected.
  """

  # async: false — the sweep reads the whole ledger and the whole issue table.
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.BudgetPatrol
  alias Arbiter.Usage.Event

  require Ash.Query

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "patrol-ws-#{System.unique_integer([:positive])}",
        prefix: "pw"
      })

    # n=10 closed D2 features costing $1..$10 → p25 $3, p75 $8, p90 $9.
    Enum.each(1..10, fn n ->
      issue = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(issue.id, ws, %{cost_usd: n * 1.0})
    end)

    %{ws: ws}
  end

  defp open_issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "patrol subject", workspace_id: ws.id}, attrs))

    issue
  end

  defp closed_issue!(ws, attrs) do
    issue = open_issue!(ws, attrs)
    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  defp event!(task_id, ws, attrs) do
    base = %{
      task_id: task_id,
      base_task_id: task_id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: @now
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  defp escalations(ws), do: Message.inbox(Message.coordinator_ref(), workspace_id: ws.id)

  # Every escalation row for the workspace, read or not — `inbox/2` only shows
  # the unread ones, and the dedupe is supposed to outlive a read.
  defp all_escalations(ws) do
    kind = :escalation
    ws_id = ws.id

    Message
    |> Ash.Query.filter(workspace_id == ^ws_id and kind == ^kind)
    |> Ash.read!()
  end

  describe "sweep/1" do
    test "an open task past p90 gets exactly one escalation, naming the numbers", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature, title: "runaway task"})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [escalation] = escalations(ws)
      assert escalation.kind == :escalation
      assert Message.task_ref(escalation) == task.id
      assert escalation.subject =~ task.id
      # The fields the coordinator needs to judge whether this is expected.
      assert escalation.body =~ "runaway task"
      assert escalation.body =~ "$40.00"
      assert escalation.body =~ "$3.00"
      assert escalation.body =~ "$9.00"
      assert escalation.body =~ "difficulty+type"
      assert escalation.body =~ "n=10"
      assert escalation.body =~ "D2"
      # And the copy is honest about what the figure covers.
      assert escalation.body =~ "worker spend"
    end

    test "a second sweep does not escalate again", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)
      # More spend arrives, and the sweep runs again — as it does every tick.
      event!(task.id, ws, %{cost_usd: 10.0, step: :review})
      assert :ok = BudgetPatrol.sweep(now: @now)
      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [_only_one] = escalations(ws)
    end

    test "a read escalation still suppresses the repeat — the dedupe is durable", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)
      assert [escalation] = escalations(ws)
      {:ok, _} = Message.mark_read(escalation)

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [_still_only_one] = all_escalations(ws)
    end

    test "a closed task that ran over is never escalated", %{ws: ws} do
      task = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [] = escalations(ws)
    end

    test "a task under p90 is not escalated", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 8.5})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [] = escalations(ws)
    end

    test "a task with no estimate is never escalated, however much it has spent", %{ws: ws} do
      # D4 has no history of its own, and `min_n: 10` keeps it off the global
      # rung too — so there is no p90 to be over.
      task = open_issue!(ws, %{difficulty: 4, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 500.0})

      assert :ok = BudgetPatrol.sweep(now: @now, min_n: 11)

      assert [] = escalations(ws)
    end
  end

  # The sweep above is called directly; this drives the process the
  # application actually supervises — `init/1` -> a `:poll` call -> the same
  # sweep — so the GenServer wiring is proven, not just the function under it.
  describe "the supervised ticker" do
    test "a poll on the running process escalates the same way", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      pid = start_supervised!({BudgetPatrol, name: nil, enabled: false})

      assert :ok = BudgetPatrol.poll(pid)

      assert [escalation] = escalations(ws)
      assert escalation.subject == CoordinatorNotifier.budget_exceeded_subject(task.id)
    end
  end
end
