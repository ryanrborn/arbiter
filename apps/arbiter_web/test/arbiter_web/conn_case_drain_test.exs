defmodule ArbiterWeb.ConnCaseDrainTest do
  # Deliberately does *not* `use ArbiterWeb.ConnCase` — that would install the
  # very `on_exit` drain under test and confuse the timings. These tests drive
  # `drain_live_views/2` directly against stand-in processes.
  use ExUnit.Case, async: true

  @fake_live_view_initial_call {Phoenix.LiveView.Channel, :init, 1}

  test "returns as soon as this test's LiveViews are gone" do
    test_pid = self()
    pid = fake_live_view(test_pid)

    send(pid, :stop)

    assert ArbiterWeb.ConnCase.drain_live_views(test_pid, 2_000) == :ok
    refute Process.alive?(pid)
  end

  # The timeout is a bound on the whole drain. Handing each LiveView the full
  # remaining budget in turn makes the worst case N x timeout instead, which
  # for a test that mounted a handful of LiveViews turns a 200ms teardown cap
  # into a multi-second one.
  test "bounds the whole drain, not each LiveView in turn" do
    test_pid = self()
    pids = for _ <- 1..5, do: fake_live_view(test_pid)
    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

    {micros, :ok} = :timer.tc(fn -> ArbiterWeb.ConnCase.drain_live_views(test_pid, 200) end)

    assert div(micros, 1000) < 500
  end

  test "ignores LiveViews belonging to another test" do
    other_test_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other_test_pid, :kill) end)
    pid = fake_live_view(other_test_pid)
    on_exit(fn -> Process.exit(pid, :kill) end)

    {micros, :ok} = :timer.tc(fn -> ArbiterWeb.ConnCase.drain_live_views(self(), 500) end)

    assert div(micros, 1000) < 100
    assert Process.alive?(pid)
  end

  # A process that looks to `drain_live_views/2` exactly like a LiveView
  # channel owned by `test_pid`, and that never exits on its own.
  defp fake_live_view(test_pid) do
    parent = self()

    pid =
      spawn(fn ->
        Process.put(:"$initial_call", @fake_live_view_initial_call)
        Process.put(:"$ancestors", [test_pid])
        send(parent, {:ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:ready, ^pid} -> pid
    after
      1_000 -> flunk("stand-in LiveView never started")
    end
  end
end
