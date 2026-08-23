defmodule Arbiter.Board.AutopilotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  # A board with one promotable card, as `Snapshot.derive/1` would return it.
  defp board(promote, paused? \\ false) do
    %{
      ready: [
        %{id: "bd-1", state: :next, reason: "next up — dispatching...", card: %{id: "bd-1"}}
      ],
      running: [],
      waiting: [],
      closed_today: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  # Start an autopilot that never ticks on its own — every test drives it by
  # hand so there is no race between the timer and the assertion.
  defp start(opts) do
    test = self()

    defaults = [
      name: nil,
      interval_ms: :never,
      snapshot: fn opts -> board("bd-1", opts[:paused]) end,
      dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "promotion" do
    test "dispatches the card the scheduler promoted" do
      pid = start(paused: false)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_receive {:dispatched, "bd-1"}
    end

    test "dispatches nothing when the scheduler promotes nothing" do
      pid = start(paused: false, snapshot: fn _ -> board(nil) end)

      assert :idle = Autopilot.tick(pid)
      refute_receive {:dispatched, _}
    end

    test "a failed dispatch neither crashes the autopilot nor retries in the same tick" do
      pid = start(paused: false, dispatch: fn _ -> {:error, :no_repo} end)

      assert {:error, :no_repo} = Autopilot.tick(pid)
      assert Process.alive?(pid)
    end
  end

  describe "a dispatch does not take the process with it" do
    # The board refreshes *because* a dispatch is happening — Worker.init
    # broadcasts :started mid-flight — so the one moment every open board asks
    # this process a question is the moment a synchronous dispatch would have
    # it blocked. Dispatch is seconds to minutes; the call timeout is five.
    test "the autopilot keeps answering while a promotion is in flight" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            send(test, {:dispatch_started, id, self()})
            assert_receive :release, 2_000
            {:ok, %{task_id: id}}
          end
        )

      spawn_link(fn -> send(test, {:tick_outcome, Autopilot.tick(pid)}) end)
      assert_receive {:dispatch_started, "bd-1", task}

      # Mid-dispatch, and every one of these answers promptly.
      assert Autopilot.paused?(pid, 200) == false
      assert %{paused: false} = Autopilot.board(pid, [], 200)
      assert :ok = Autopilot.pause(pid)
      assert :ok = Autopilot.resume(pid)

      send(task, :release)
      # The tick that started it still gets the outcome, once there is one.
      assert_receive {:tick_outcome, {:ok, "bd-1"}}
    end

    test "a tick that lands mid-dispatch does not start a second one" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            send(test, {:dispatch_started, id, self()})
            assert_receive :release, 2_000
            {:ok, %{task_id: id}}
          end
        )

      spawn_link(fn -> send(test, {:tick_outcome, Autopilot.tick(pid)}) end)
      assert_receive {:dispatch_started, "bd-1", task}

      assert {:busy, "bd-1"} = Autopilot.tick(pid, 200)
      refute_receive {:dispatch_started, _, _}, 50

      send(task, :release)
      assert_receive {:tick_outcome, {:ok, "bd-1"}}
    end
  end

  describe "the pause switch" do
    test "starts paused when asked, and dispatches nothing while paused" do
      pid = start(paused: true)

      assert Autopilot.paused?(pid)
      assert :paused = Autopilot.tick(pid)
      refute_receive {:dispatched, _}
    end

    test "resume lets the next tick promote; pause stops it again" do
      pid = start(paused: true)

      assert :ok = Autopilot.resume(pid)
      refute Autopilot.paused?(pid)
      assert {:ok, "bd-1"} = Autopilot.tick(pid)

      assert :ok = Autopilot.pause(pid)
      assert :paused = Autopilot.tick(pid)
    end

    test "the board it hands out carries its own pause state, so reasons match reality" do
      pid = start(paused: true)

      assert %{paused: true} = Autopilot.board(pid)

      Autopilot.resume(pid)
      assert %{paused: false} = Autopilot.board(pid)
    end
  end

  describe "a board read that blows up" do
    test "a failed read promotes nothing rather than crashing the autopilot" do
      pid = start(paused: false, snapshot: fn _ -> raise "no repo" end)

      assert :idle = Autopilot.tick(pid)
      assert Process.alive?(pid)
      refute_receive {:dispatched, _}
    end

    test "the board it hands out is still a board a screen can render" do
      pid = start(paused: false, snapshot: fn _ -> raise "no repo" end)

      board = Autopilot.board(pid)

      # Every column key present and empty, not a stub map: the caller renders
      # four columns off this, and a missing key is a crashed page.
      assert board.ready == []
      assert board.running == []
      assert board.waiting == []
      assert board.closed_today == []
      assert board.promote == nil
      assert board.slots_free == 0
      assert %DateTime{} = board.now
      # It reports itself paused: nothing is draining a queue it cannot read.
      assert board.paused
    end
  end

  describe "announcements" do
    test "a promotion is broadcast so open boards refresh without polling" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      pid = start(paused: false)

      Autopilot.tick(pid)

      assert_receive {:board_dispatched, "bd-1"}
    end

    test "pausing and resuming are broadcast too" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      pid = start(paused: false)

      Autopilot.pause(pid)
      assert_receive {:board_scheduler, :paused}

      Autopilot.resume(pid)
      assert_receive {:board_scheduler, :resumed}
    end
  end
end
