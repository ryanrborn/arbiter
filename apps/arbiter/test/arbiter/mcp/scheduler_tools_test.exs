defmodule Arbiter.MCP.SchedulerToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "scheduler-tools-ws-#{System.unique_integer([:positive])}",
        prefix: "stw#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id}

    # Start an autopilot instance for testing
    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        snapshot: fn opts -> default_board(opts[:paused]) end
      )

    on_exit(fn ->
      # Ensure the autopilot is stopped
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, ws: ws, coordinator: coordinator}
  end

  defp default_board(paused?) do
    %{
      ready: [],
      running: [],
      waiting: [],
      closed_today: [],
      promote: nil,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  describe "scheduler_pause/2" do
    test "pauses the autopilot", ctx do
      # Ensure we start in resumed state
      :ok = Autopilot.resume()

      assert false == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_pause(ctx.coordinator, %{})

      assert data.paused == true
      assert Autopilot.paused?() == true
    end

    test "returns current state when already paused", ctx do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_pause(ctx.coordinator, %{})

      assert data.paused == true
    end
  end

  describe "scheduler_resume/2" do
    test "resumes the autopilot", ctx do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_resume(ctx.coordinator, %{})

      assert data.paused == false
      assert Autopilot.paused?() == false
    end

    test "returns current state when already running", ctx do
      :ok = Autopilot.resume()
      assert false == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_resume(ctx.coordinator, %{})

      assert data.paused == false
    end
  end

  describe "scheduler_status/2" do
    test "returns the current pause state", ctx do
      :ok = Autopilot.pause()

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.paused == true
    end

    test "returns running state", ctx do
      :ok = Autopilot.resume()

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.paused == false
    end
  end
end
