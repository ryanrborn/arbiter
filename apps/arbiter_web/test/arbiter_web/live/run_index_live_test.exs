defmodule ArbiterWeb.RunIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Workers.Run

  defp run(attrs) do
    {:ok, r} =
      Ash.create(
        Run,
        Map.merge(
          %{
            repo: "arbiter",
            workspace_id: "ws-1",
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            completed_at: DateTime.utc_now()
          },
          attrs
        )
      )

    r
  end

  test "lists completed and failed runs, linking to the run detail page", %{conn: conn} do
    completed = run(%{task_id: "bd-ok", task_title: "the-good-run", status: :completed})
    _failed = run(%{task_id: "bd-bad", task_title: "the-bad-run", status: :failed})

    {:ok, _view, html} = live(conn, ~p"/workers/history")

    assert html =~ ~s(id="runs")
    assert html =~ "the-good-run"
    assert html =~ "the-bad-run"
    assert html =~ ~s(href="/workers/history/#{completed.id}")
  end

  test "the failed filter excludes completed runs", %{conn: conn} do
    _completed = run(%{task_id: "bd-ok2", task_title: "completed-only", status: :completed})
    _failed = run(%{task_id: "bd-bad2", task_title: "failed-only", status: :failed})

    {:ok, _view, html} = live(conn, ~p"/workers/history?#{%{status: :failed}}")

    assert html =~ "failed-only"
    refute html =~ "completed-only"
  end
end
