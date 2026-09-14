defmodule Arbiter.Test.SandboxMonitorTest do
  @moduledoc """
  bd-5scl0c: the monitor's job is to notice a killed sandbox client at all, and
  to tell the two classes apart — a live test losing its connection (a bug) vs
  a process dying after its test had already exited (noise).
  """
  use ExUnit.Case, async: true

  require Logger

  alias Arbiter.Test.SandboxMonitor

  @disconnect ~S|Exqlite.Connection (#PID<0.1.0> ("db_conn_1")) disconnected: | <>
                ~S|** (DBConnection.ConnectionError) client #PID<0.2.0> exited|

  describe "classify/1" do
    test "a registered test that is still running means the connection was pulled mid-test" do
      assert SandboxMonitor.classify([{self(), SomeTest, "a test", true}]) == :mid_test
    end

    test "only exited test processes means the kill landed in teardown" do
      assert SandboxMonitor.classify([{self(), SomeTest, "a test", false}]) == :teardown
    end

    test "no registered test at all is teardown, not a mid-test loss" do
      assert SandboxMonitor.classify([]) == :teardown
    end

    test "one live test among exited ones is enough to call it mid-test" do
      running = [{self(), A, "gone", false}, {self(), B, "live", true}]
      assert SandboxMonitor.classify(running) == :mid_test
    end
  end

  describe "log/2" do
    test "records a client-exited disconnect, with the tests registered at that moment" do
      test_pid = self()
      SandboxMonitor.track(test_pid, __MODULE__, "log/2 probe")
      on_exit(fn -> SandboxMonitor.untrack(test_pid) end)

      # Filter on a marker rather than subtracting a snapshot: this module is
      # async: true, so a genuine disconnect logged anywhere in the VM during
      # the window would otherwise land in the diff and fail the assertion.
      marker = marker("log")
      SandboxMonitor.log(%{msg: {:string, @disconnect <> " " <> marker}}, %{})

      assert [{:incident, text, running} = incident] = incidents_matching(marker)
      assert text =~ "client #PID<0.2.0> exited"
      assert {_pid, __MODULE__, "log/2 probe", true} = List.keyfind(running, self(), 0)

      # Do not leave a synthetic incident behind: it would be counted in the
      # end-of-suite report as if it were real.
      SandboxMonitor.forget(incident)
    end

    test "ignores ordinary log lines" do
      marker = marker("ignore")

      SandboxMonitor.log(
        %{msg: {:string, "Worker.Watchdog: auto-merge failed; will retry #{marker}"}},
        %{}
      )

      assert incidents_matching(marker) == []
    end
  end

  describe "install/0" do
    # Every other test here drives `log/2` directly, so they would all keep
    # passing if `install/0` never wired the handler into `:logger` at all —
    # the monitor would go silently blind and the suite would stay green. This
    # is the one test that goes the whole way through the real logger.
    test "the installed handler receives a real error-level disconnect" do
      marker = marker("install")

      ExUnit.CaptureLog.capture_log(fn -> Logger.error(@disconnect <> " " <> marker) end)

      assert [{:incident, text, running} = incident] = incidents_matching(marker)

      assert text =~ "client #PID<0.2.0> exited"
      assert SandboxMonitor.classify(running) in [:mid_test, :teardown]

      # Do not leave a synthetic incident behind: it would be counted in the
      # end-of-suite report as if it were real.
      SandboxMonitor.forget(incident)
    end
  end

  defp marker(label), do: "sandbox-monitor-#{label}-probe-#{System.unique_integer([:positive])}"

  defp incidents_matching(marker) do
    Enum.filter(SandboxMonitor.incidents(), fn {:incident, text, _running} ->
      String.contains?(text, marker)
    end)
  end
end
