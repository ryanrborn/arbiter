defmodule Arbiter.Test.SandboxMonitorTest do
  @moduledoc """
  bd-5scl0c: the monitor's job is to notice a killed sandbox client at all, and
  to tell the two classes apart — a live test losing its connection (a bug) vs
  a process dying after its test had already exited (noise).
  """
  use ExUnit.Case, async: true

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

      before = SandboxMonitor.incidents()
      SandboxMonitor.log(%{msg: {:string, @disconnect}}, %{})
      recorded = SandboxMonitor.incidents() -- before

      assert [{:incident, text, running} = incident] = recorded
      assert text =~ "client #PID<0.2.0> exited"
      assert {_pid, __MODULE__, "log/2 probe", true} = List.keyfind(running, self(), 0)

      # Do not leave a synthetic incident behind: it would fail the real run.
      SandboxMonitor.forget(incident)
    end

    test "ignores ordinary log lines" do
      before = SandboxMonitor.incidents()
      SandboxMonitor.log(%{msg: {:string, "Worker.Watchdog: auto-merge failed; will retry"}}, %{})
      assert SandboxMonitor.incidents() -- before == []
    end
  end
end
