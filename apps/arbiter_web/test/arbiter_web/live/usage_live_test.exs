defmodule ArbiterWeb.UsageLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "usage-#{System.unique_integer([:positive])}", prefix: "usg"})

    {:ok, ws: ws}
  end

  defp new_issue!(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    issue
  end

  defp event!(attrs) do
    base = %{
      repo: "arbiter",
      step: :work,
      occurred_at: DateTime.utc_now(),
      model: "sonnet"
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  test "renders header, stat row, and the by-task table", %{conn: conn, ws: ws} do
    single = new_issue!(ws, "Collapse duplicate status helpers")
    reworked = new_issue!(ws, "Loop proposal queue: apply / reject")

    event!(%{
      task_id: single.id,
      workspace_id: ws.id,
      cost_usd: 0.42,
      tokens_in: 30_000,
      tokens_out: 8_400
    })

    event!(%{
      task_id: reworked.id,
      workspace_id: ws.id,
      cost_usd: 0.60,
      tokens_in: 40_000,
      tokens_out: 10_000
    })

    event!(%{
      task_id: reworked.id,
      workspace_id: ws.id,
      cost_usd: 0.28,
      tokens_in: 10_000,
      tokens_out: 4_000
    })

    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "Usage"
    assert html =~ "Total spend"
    assert html =~ "$1.30"
    assert html =~ "Rework tasks"
    assert html =~ single.id
    assert html =~ "Collapse duplicate status helpers"
    assert html =~ reworked.id
  end

  test "rework metrics collapse ReviewGate synthetic task ids to the base task", %{
    conn: conn,
    ws: ws
  } do
    task = new_issue!(ws, "Probe task two")
    now = DateTime.utc_now()

    event!(%{
      task_id: task.id,
      workspace_id: ws.id,
      step: :work,
      cost_usd: 2.0,
      occurred_at: DateTime.add(now, -20, :minute)
    })

    event!(%{
      task_id: "#{task.id}#review",
      workspace_id: ws.id,
      step: :work,
      cost_usd: 1.0,
      occurred_at: DateTime.add(now, -10, :minute)
    })

    event!(%{
      task_id: "#{task.id}#review",
      workspace_id: ws.id,
      step: :review,
      cost_usd: 0.5,
      occurred_at: now
    })

    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "$3.50"
    assert [_] = Regex.scan(~r/Probe task two/, html)
    assert html =~ "$1.00"
    refute html =~ "$2.00"
  end

  test "switching to the By model tab renders per-model bars", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Some task")
    event!(%{task_id: task.id, workspace_id: ws.id, model: "claude-sonnet-4-6", cost_usd: 1.0})
    event!(%{task_id: task.id, workspace_id: ws.id, model: "claude-opus-4-6", cost_usd: 0.5})

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-tab=by_model]")
      |> render_click()

    assert html =~ "Sonnet"
    assert html =~ "Opus"
  end

  test "switching to the By repo tab renders per-repo bars", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Some task")
    event!(%{task_id: task.id, workspace_id: ws.id, repo: "arbiter", cost_usd: 1.0})
    event!(%{task_id: task.id, workspace_id: ws.id, repo: "verus-api", cost_usd: 0.4})

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-tab=by_repo]")
      |> render_click()

    assert html =~ "arbiter"
    assert html =~ "verus-api"
  end

  test "changing the range segmented control reloads data", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Old task")

    event!(%{
      task_id: task.id,
      workspace_id: ws.id,
      cost_usd: 5.0,
      occurred_at: DateTime.add(DateTime.utc_now(), -40, :day)
    })

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-option='all']")
      |> render_click()

    assert html =~ "$5.00"

    html =
      view
      |> element("button[phx-value-option='7d']")
      |> render_click()

    refute html =~ "$5.00"
  end

  test "shows an empty state when there is no usage yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")
    assert html =~ "Usage"
    assert html =~ "$0.00"
  end

  test "renders Rate limits and Rework panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")
    assert html =~ "Rate limits"
    assert html =~ "Rework"
    assert html =~ "hairline is elapsed time"
  end

  test "stat row and spend/rate-limits panels use responsive grid layouts for mobile", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")
    # Stat row should stack 2x2 on mobile (grid-cols-2) and 4-across on desktop (sm:grid-cols-4)
    assert html =~ "grid-cols-2"
    assert html =~ "sm:grid-cols-4"
    # Spend/Rate-limits should stack vertically on mobile (grid-cols-1) and side-by-side on desktop
    assert html =~ "grid-cols-1"
    assert html =~ "lg:grid-cols-[minmax(0,1fr)_320px]"
  end
end
