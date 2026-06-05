defmodule Arbiter.SingleInstanceTest do
  # async: false — each guard claims an ETS slot and writes a PID file under a
  # per-test lock_key temp path. Unique lock keys keep tests from colliding.
  use ExUnit.Case, async: false

  alias Arbiter.SingleInstance

  defp start_guard(name, lock_key) do
    {:ok, pid} = SingleInstance.start_link(name: name, lock_key: lock_key)

    # The guard is linked to (and parented by) the test process, so it exits
    # :shutdown when the test ends — tolerate that in teardown rather than
    # racing GenServer.stop/3 against it.
    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  test "the first guard wins the lock; a concurrent second guard is secondary" do
    lock_key = System.unique_integer([:positive])

    start_guard(:single_instance_first, lock_key)
    start_guard(:single_instance_second, lock_key)

    # Exactly one instance may sweep: the one that holds the advisory lock. This
    # is what stops a duplicate boot from failing the primary's live runs.
    assert SingleInstance.primary?(:single_instance_first)
    refute SingleInstance.primary?(:single_instance_second)
  end

  test "the lock is released when the primary stops, so the next instance can claim it" do
    lock_key = System.unique_integer([:positive])

    first = start_guard(:single_instance_restart_a, lock_key)
    assert SingleInstance.primary?(:single_instance_restart_a)

    # A genuine single-server restart: the primary goes away (releasing the
    # lock via its closed session), and the replacement re-acquires it — so
    # crash recovery still runs on the one canonical instance.
    GenServer.stop(first)

    start_guard(:single_instance_restart_b, lock_key)
    assert SingleInstance.primary?(:single_instance_restart_b)
  end

  test "primary?/0 returns false when the guard is not running" do
    # Fail safe: a missing guard must never green-light the destructive sweep.
    refute SingleInstance.primary?(:single_instance_absent)
  end
end
