defmodule ArbiterWeb.Api.SchedulerControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Board.Autopilot

  setup do
    # Start an autopilot instance for testing
    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        snapshot: fn opts ->
          %{
            ready: [],
            running: [],
            waiting: [],
            closed_today: [],
            promote: nil,
            slots_total: 4,
            slots_free: 4,
            quota: :ok,
            paused: opts[:paused],
            now: DateTime.utc_now()
          }
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end

      # Reset the global Autopilot singleton to paused state to prevent test pollution
      Autopilot.pause(Autopilot)
    end)

    {:ok, pid: pid}
  end

  describe "POST /api/scheduler/pause" do
    test "pauses the scheduler", %{conn: conn} do
      :ok = Autopilot.resume()
      assert false == Autopilot.paused?()

      conn = post(conn, "/api/scheduler/pause")

      assert %{"paused" => true, "changed_by" => "api", "changed_at" => changed_at} =
               json_response(conn, 200)

      assert is_binary(changed_at)
      assert Autopilot.paused?() == true
    end
  end

  describe "POST /api/scheduler/resume" do
    test "resumes the scheduler", %{conn: conn} do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      conn = post(conn, "/api/scheduler/resume")

      assert %{"paused" => false, "changed_by" => "api", "changed_at" => changed_at} =
               json_response(conn, 200)

      assert is_binary(changed_at)
      assert Autopilot.paused?() == false
    end
  end

  describe "GET /api/scheduler/status" do
    test "returns the current pause state", %{conn: conn} do
      :ok = Autopilot.pause()

      conn = get(conn, "/api/scheduler/status")

      assert %{"paused" => true} = json_response(conn, 200)
    end

    test "returns running state", %{conn: conn} do
      :ok = Autopilot.resume()

      conn = get(conn, "/api/scheduler/status")

      assert %{"paused" => false} = json_response(conn, 200)
    end
  end
end
