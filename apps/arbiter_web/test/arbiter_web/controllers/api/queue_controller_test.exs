defmodule ArbiterWeb.Api.QueueControllerTest do
  @moduledoc """
  bd-8jixav: `POST /api/queue/:task_id/restart_watchdog` — the REST half of the
  dead-Watchdog recovery, and the endpoint `arb queue restart-watchdog` drives.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger

  setup %{conn: conn} do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "queue-ctrl-ws-#{System.unique_integer([:positive])}",
        prefix: "qc"
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp parked_worker(ws, mr_ref) do
    {:ok, task} = Ash.create(Issue, %{title: "queue ctrl", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "qc/repo", workspace_id: ws.id)
    on_exit(fn -> Process.alive?(pid) && Worker.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :implement)

    StubMerger.next_open_ref(mr_ref)
    StubMerger.queue_get(mr_ref, [%{status: :open, approved: false}])

    {:ok, ^mr_ref} =
      Worker.open_mr(pid, "feature/#{mr_ref}", "MR", "desc", %{
        adapter: StubMerger,
        workspace: nil,
        interval_ms: 50,
        initial_delay_ms: 0,
        watchdog_start_error: true
      })

    on_exit(fn ->
      case Watchdog.whereis(task.id) do
        nil -> :ok
        wpid -> GenServer.stop(wpid, :normal)
      end
    end)

    {task, pid}
  end

  describe "POST /api/queue/:task_id/restart_watchdog" do
    test "restarts a dead watchdog for a parked worker", %{conn: conn, ws: ws} do
      {task, _pid} = parked_worker(ws, "!qc1")
      refute Watchdog.alive?(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"restarted" => true, "task_id" => id} = json_response(conn, 200)
      assert id == task.id
      assert Watchdog.alive?(task.id)
    end

    test "404s when no worker is registered for the task", %{conn: conn} do
      conn = post(conn, ~p"/api/queue/no-such-task-xyz/restart_watchdog", %{})
      assert json_response(conn, 404)
    end

    test "409s rather than stacking a second watchdog on one MR", %{conn: conn, ws: ws} do
      {task, _pid} = parked_worker(ws, "!qc2")
      assert :ok = Watchdog.restart(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 409)
      assert msg =~ "already running"
    end

    test "400s when the worker is not parked awaiting review", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "not parked", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "qc/repo", workspace_id: ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :implement)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "awaiting_review"
    end
  end
end
