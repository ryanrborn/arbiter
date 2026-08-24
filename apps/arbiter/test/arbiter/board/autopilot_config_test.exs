defmodule Arbiter.Board.AutopilotConfigTest do
  use ExUnit.Case, async: false

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

    # Check if the test wants to use the real default_dispatch (for testing with mocks)
    use_real_dispatch = Keyword.get(opts, :use_real_dispatch, false)
    opts = Keyword.delete(opts, :use_real_dispatch)

    defaults = [
      name: nil,
      interval_ms: :never,
      snapshot: fn opts -> board("bd-1", opts[:paused]) end
    ]

    # Only include the mock dispatch if not using the real one
    defaults =
      if use_real_dispatch do
        defaults
      else
        defaults ++
          [dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end]
      end

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "boot-time defaults from app config" do
    test "with no :board_autopilot config, autopilot starts paused" do
      # Save the current config
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        # Clear the config to simulate a fresh install with no config set
        Application.delete_env(:arbiter, :board_autopilot)

        # Start autopilot without explicit :paused option — should use the app config default
        pid = start(name: nil, interval_ms: :never, snapshot: fn _ -> board(nil) end)

        # With no config, it should start paused (safe default)
        assert true === Autopilot.paused?(pid)
        assert :paused = Autopilot.tick(pid)
      after
        # Restore the original config
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end

    test "with enabled: true in config, autopilot starts unpaused" do
      # Save the current config
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        # Set the config to enable autopilot
        Application.put_env(:arbiter, :board_autopilot, enabled: true)

        # Start autopilot without explicit :paused option — should use the app config default
        pid = start(name: nil, interval_ms: :never, snapshot: fn _ -> board("bd-1") end)

        # With enabled: true, it should start unpaused
        assert false === Autopilot.paused?(pid)
        assert {:ok, "bd-1"} = Autopilot.tick(pid)
      after
        # Restore the original config
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end
  end
end
