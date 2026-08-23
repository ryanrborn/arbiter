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

  test "lists completed and failed runs with the new component structure", %{conn: conn} do
    completed =
      run(%{
        task_id: "bd-ok",
        task_title: "the-good-run",
        status: :completed,
        worker_type: "main"
      })

    _failed =
      run(%{task_id: "bd-bad", task_title: "the-bad-run", status: :failed, worker_type: "review"})

    {:ok, _view, html} = live(conn, ~p"/workers/history")

    # Check for new component structure
    assert html =~ ~s(id="runs-history")
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

  test "empty state uses the moon icon when no runs match", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers/history?#{%{status: :running}}")

    # Moon icon should be present in empty state
    assert html =~ "runs-empty"
    assert html =~ "hero-moon"
  end
end
