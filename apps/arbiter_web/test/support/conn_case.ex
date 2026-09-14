defmodule ArbiterWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. SQLite with WAL mode
  supports concurrent readers; `async: true` is safe for
  read-heavy tests, but the sandbox serialises writes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ArbiterWeb.Endpoint

      use ArbiterWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ArbiterWeb.ConnCase
    end
  end

  setup tags do
    Arbiter.DataCase.setup_sandbox(tags)

    # Registered after `setup_sandbox/1`, so it runs *first* (`on_exit` is
    # LIFO) — before the leaked-child sweep and before `stop_owner`.
    test_pid = self()
    on_exit(fn -> drain_live_views(test_pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @drain_timeout 2_000

  @doc """
  Wait for this test's LiveView processes to actually be gone (bd-5scl0c).

  `Phoenix.LiveViewTest` links each LiveView to a proxy that is linked to the
  test process, and ExUnit exits the test process with `:shutdown`. That signal
  kills `Phoenix.LiveView.Channel` outright — it does not trap exits — so a
  LiveView still handling a queued PubSub echo dies mid-query, drops the single
  shared sandbox connection and destroys the owning
  `DBConnection.Ownership.Proxy`.

  Exit signals are delivered asynchronously, so that death regularly landed a
  few microseconds into the *next* test — which, in shared mode, is by then the
  owner of the connection being dropped. That test then fails somewhere
  unrelated with `DBConnection.OwnershipError`, or silently reads back nothing.

  `on_exit` runs after the test process is gone but before the next test
  starts, so waiting here keeps the fallout inside the owning test's teardown,
  where the connection is about to be handed back anyway. Only this test's own
  LiveViews are waited on (matched via `$ancestors`), so a concurrently
  running `async: true` test is never blocked on.
  """
  def drain_live_views(test_pid, timeout \\ @drain_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_live_views(test_pid, deadline)
  end

  defp await_live_views(test_pid, deadline) do
    case live_views_of(test_pid) do
      [] ->
        :ok

      pids ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Enum.each(pids, &await_down(&1, remaining))
          await_live_views(test_pid, deadline)
        else
          :ok
        end
    end
  end

  defp await_down(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush])
    end
  end

  defp live_views_of(test_pid) do
    for pid <- Process.list(),
        initial_call(pid) == {Phoenix.LiveView.Channel, :init, 1},
        test_pid in ancestors(pid),
        do: pid
  end

  defp initial_call(pid), do: dict_key(pid, :"$initial_call")

  defp ancestors(pid) do
    case dict_key(pid, :"$ancestors") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # `process_info/2` can fetch a single process-dictionary key (OTP 26+), which
  # keeps this scan cheap enough to run after every test.
  defp dict_key(pid, key) do
    case :erlang.process_info(pid, {:dictionary, key}) do
      {{:dictionary, ^key}, value} -> value
      _ -> nil
    end
  end
end
