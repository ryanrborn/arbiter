defmodule ArbiterWeb.Api.RunControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Workers.Run

  @ws "ws-api-run"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_run!(attrs) do
    base = %{
      task_id: "bd-#{System.unique_integer([:positive])}",
      repo: "arbiter",
      workspace_id: @ws,
      status: :running,
      started_at: DateTime.utc_now()
    }

    {:ok, run} = Ash.create(Run, Map.merge(base, attrs))
    run
  end

  describe "GET /api/workers/history" do
    test "lists runs newest first, scoped to workspace and status", %{conn: conn} do
      now = DateTime.utc_now()
      older = DateTime.add(now, -10, :second)
      newer = DateTime.add(now, 0, :second)

      _ = insert_run!(%{task_id: "bd-h1", started_at: older, status: :completed})
      _ = insert_run!(%{task_id: "bd-h2", started_at: newer, status: :completed})
      _ = insert_run!(%{task_id: "bd-h3", started_at: newer, status: :failed})
      _ = insert_run!(%{task_id: "bd-h4", started_at: newer, workspace_id: "other"})

      conn = get(conn, ~p"/api/workers/history", %{workspace_id: @ws, status: "completed"})
      data = json_response(conn, 200)["data"]
      ids = Enum.map(data, & &1["task_id"])
      assert ids == ["bd-h2", "bd-h1"]
      # Summary view omits output_lines (only :show returns them).
      refute Map.has_key?(List.first(data), "output_lines")
    end

    test "limit caps results", %{conn: conn} do
      for i <- 1..5 do
        insert_run!(%{
          task_id: "bd-lim#{i}",
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), -i, :second)
        })
      end

      conn = get(conn, ~p"/api/workers/history", %{workspace_id: @ws, limit: "2"})
      assert length(json_response(conn, 200)["data"]) == 2
    end

    test "before cursor filters to earlier started_at", %{conn: conn} do
      a = insert_run!(%{task_id: "bd-c1", started_at: ~U[2026-05-27 10:00:00.000000Z]})
      _ = insert_run!(%{task_id: "bd-c2", started_at: ~U[2026-05-27 12:00:00.000000Z]})

      conn =
        get(conn, ~p"/api/workers/history", %{
          workspace_id: @ws,
          before: "2026-05-27T11:00:00Z"
        })

      data = json_response(conn, 200)["data"]
      assert Enum.map(data, & &1["task_id"]) == [a.task_id]
    end

    test "invalid status returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/workers/history", %{status: "nope"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "task_id filter lists every run for one task, newest first", %{conn: conn} do
      task = "bd-hist-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      _ =
        insert_run!(%{
          task_id: task,
          worker_type: :main,
          model: "claude-opus-4-8",
          status: :completed,
          started_at: DateTime.add(now, -20, :second)
        })

      _ =
        insert_run!(%{
          task_id: task,
          worker_type: :review,
          status: :completed,
          started_at: DateTime.add(now, -5, :second)
        })

      # A run for a different task must NOT leak into the per-task history.
      _ = insert_run!(%{task_id: "bd-other-#{System.unique_integer([:positive])}"})

      conn = get(conn, ~p"/api/workers/history", %{task_id: task})
      data = json_response(conn, 200)["data"]

      assert length(data) == 2
      # Newest first: the review run precedes the main run.
      assert Enum.map(data, & &1["worker_type"]) == ["review", "main"]
      # Summary carries the worker_type + model surfaced in the history list.
      assert List.last(data)["model"] == "claude-opus-4-8"
    end
  end

  describe "GET /api/workers/history/:id" do
    test "returns the run with full output_lines", %{conn: conn} do
      run =
        insert_run!(%{
          task_id: "bd-show",
          status: :completed,
          completed_at: DateTime.utc_now(),
          output_lines: ["one", "two", "three"]
        })

      conn = get(conn, ~p"/api/workers/history/#{run.id}")
      data = json_response(conn, 200)["data"]
      assert data["task_id"] == "bd-show"
      assert data["output_lines"] == ["one", "two", "three"]
    end

    test "404 on unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/workers/history/00000000-0000-0000-0000-000000000000")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
