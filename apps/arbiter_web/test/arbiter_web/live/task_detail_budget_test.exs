defmodule ArbiterWeb.TaskDetailBudgetTest do
  @moduledoc """
  The issue header's worker-spend figure: spend so far against the estimate
  range, and the amber / red threshold chips (bd-8j9i9p AC1/AC2/AC4, design
  bd-9jj5lf §3 and §7).
  """

  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "budget-hdr-#{System.unique_integer([:positive])}",
        prefix: "bh"
      })

    {:ok, ws: ws}
  end

  defp task!(ws, attrs) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(%{title: "header subject", workspace_id: ws.id}, attrs)
      )

    task
  end

  defp spend!(task_id, ws, cost) do
    {:ok, ev} =
      Ash.create(Event, %{
        task_id: task_id,
        base_task_id: task_id,
        source: :task,
        step: :work,
        role: "base",
        workspace_id: ws.id,
        occurred_at: @now,
        cost_usd: cost
      })

    ev
  end

  # n=10 closed D2 features costing $1..$10 → p25 $3, median $5, p75 $8, p90 $9.
  defp history!(ws) do
    Enum.each(1..10, fn n ->
      issue = task!(ws, %{difficulty: 2, issue_type: :feature})
      {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
      spend!(closed.id, ws, n * 1.0)
    end)
  end

  describe "worker spend in the header" do
    setup %{ws: ws} do
      history!(ws)
      :ok
    end

    test "shows spend so far next to the estimate range, basis and n",
         %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 4.25)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-spend")
      assert render(view) =~ "$4.25"

      estimate = view |> element("#task-spend-estimate") |> render()
      assert estimate =~ "Estimate:"
      assert estimate =~ "$3.00"
      assert estimate =~ "$8.00"
      assert estimate =~ "p90 $9.00"
      assert estimate =~ "difficulty+type"
      assert estimate =~ "n=10"
    end

    test "says 'worker spend', and the tooltip excludes coordinator overhead",
         %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 4.25)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      figure = view |> element("#task-spend-figure") |> render()

      assert figure =~ "worker spend"
      assert figure =~ "Excludes coordinator session overhead"
    end

    test "no chip below p75", %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 7.0)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-spend-chip")
    end

    test "an amber 'running high' chip between p75 and p90", %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 8.5)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-spend-chip[data-state=running_high]")
      assert view |> element("#task-spend-chip") |> render() =~ "running high"
    end

    test "a red 'over budget' chip above p90", %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 30.0)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-spend-chip[data-state=over_budget]")
      assert view |> element("#task-spend-chip") |> render() =~ "over budget"
    end

    test "the figure updates live as the ledger grows", %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 1.0)

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "$1.00"
      refute has_element?(view, "#task-spend-chip")

      spend!(task.id, ws, 29.0)

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "workers",
        {:worker_lifecycle, :completed, %{task_id: task.id}}
      )

      assert render(view) =~ "$30.00"
      assert has_element?(view, "#task-spend-chip[data-state=over_budget]")
    end
  end

  describe "worker spend in the header for an epic" do
    defp epic!(ws) do
      {:ok, epic} =
        Ash.create(Issue, %{title: "epic subject", workspace_id: ws.id, issue_type: :epic})

      epic
    end

    defp attach!(epic, child), do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

    defp ready_child!(ws, epic, attrs) do
      issue = task!(ws, Map.merge(%{issue_type: :task}, attrs))
      ready = Ash.update!(issue, %{}, action: :promote_to_ready)
      attach!(epic, ready)
      ready
    end

    setup %{ws: ws} do
      history!(ws)
      :ok
    end

    test "aggregates spend over the epic's direct children, and reads differently from a standalone issue",
         %{conn: conn, ws: ws} do
      epic = epic!(ws)
      backlog = task!(ws, %{difficulty: 2, issue_type: :feature})
      attach!(epic, backlog)
      spend!(backlog.id, ws, 1.5)

      ready = ready_child!(ws, epic, %{difficulty: 2})
      spend!(ready.id, ws, 2.5)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#task-spend")
      assert render(view) =~ "$4.00"

      figure = view |> element("#task-spend-figure") |> render()
      assert figure =~ "worker spend"
      assert figure =~ "Excludes coordinator session overhead"
      # An epic's tooltip talks about the epic's children, not a single
      # issue's own sessions — that is the standalone-path wording.
      refute figure =~ "this issue's agent sessions"

      estimate = view |> element("#task-spend-estimate") |> render()
      assert estimate =~ "Estimate:"
      # Both children have their own peer-group history here, so both
      # contribute — the label counts contributing children, not a
      # peer-group sample size ("basis, n=").
      assert estimate =~ "2 children"
      refute estimate =~ ", n="
    end

    test "a childless epic shows $0.00 and 'no estimate yet' without crashing", %{
      conn: conn,
      ws: ws
    } do
      epic = epic!(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert render(view) =~ "$0.00"
      assert view |> element("#task-spend-estimate") |> render() =~ "no estimate yet"
    end

    test "the over-budget chip on an epic refers to its children, not 'issues like this'",
         %{conn: conn, ws: ws} do
      epic = epic!(ws)
      ready = ready_child!(ws, epic, %{difficulty: 2})
      spend!(ready.id, ws, 30.0)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#task-spend-chip[data-state=over_budget]")
      title = view |> element("#task-spend-chip") |> render()
      assert title =~ "this epic&#39;s children"
      refute title =~ "issues like this"
    end
  end

  describe "without enough history" do
    test "reads 'no estimate yet' and still shows the spend", %{conn: conn, ws: ws} do
      task = task!(ws, %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 4.25)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view |> element("#task-spend-estimate") |> render() =~ "no estimate yet"
      assert render(view) =~ "$4.25"
      refute has_element?(view, "#task-spend-chip")
    end
  end
end
