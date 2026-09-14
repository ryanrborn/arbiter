defmodule Arbiter.ProcessTeardown do
  @moduledoc """
  Stop a supervised process without interrupting whatever it is doing.

  `DynamicSupervisor.terminate_child/2` sends a bare `Process.exit(child,
  :shutdown)`. None of Arbiter's per-workspace workers, patrols, machines or
  conductors trap exits, so that signal kills them the instant it arrives —
  including while they are parked inside an `Ecto` query or transaction.

  That is not merely untidy. The dying process is a DBConnection *client*
  holding a checkout, so DBConnection has to assume the connection is in an
  unknown state: it logs

      Exqlite.Connection (#PID<...>) disconnected:
        ** (DBConnection.ConnectionError) client #PID<...> exited

  drops the physical connection and rolls back the transaction that was in
  flight. In the test suite, where `pool_size: 1` means every test shares that
  one connection and `Ecto.Adapters.SQL.Sandbox` keeps a transaction open for
  the whole of each test, it also destroys the owning
  `DBConnection.Ownership.Proxy` — so the *owning test* loses its sandbox and
  every later query raises `DBConnection.OwnershipError`, usually swallowed
  into a misleading `:not_found` somewhere far from the cause (bd-5scl0c).

  `stop_child/3` quiesces first. `:sys.suspend/2` is an OTP *system* message,
  which a `gen_server`/`gen_statem` only handles once it has returned from its
  current callback — so when it replies, the child provably holds no checkout,
  and it cannot take another one while suspended (queued messages stay
  queued). Terminating it then is safe.

  A child that cannot be suspended within `timeout` (a genuinely blocked
  callback, or a process with no `sys` loop) is terminated the old way rather
  than left running: that is the pre-existing behaviour, not a regression.
  """

  # A sandboxed SQLite query is sub-millisecond, so this only has to cover the
  # tail of a callback that is already running one. It is deliberately not
  # generous: a child still inside a callback after this long is blocked on
  # something other than the DB (a `GenServer.call` to a process that just went
  # away, a shell-out), and making every teardown wait on that stalls the suite
  # far more than the rare abrupt kill costs.
  @default_timeout 500

  @doc """
  Quiesce `pid` and remove it from `supervisor`.

  Always returns `:ok`, including when the child is already gone.
  """
  @spec stop_child(module() | pid(), pid(), timeout()) :: :ok
  def stop_child(supervisor, pid, timeout \\ @default_timeout) when is_pid(pid) do
    quiesce(pid, timeout)

    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      # Not this supervisor's child after all. A suspended GenServer answers no
      # calls at all, so leaving it that way would silently time out every
      # caller for the rest of the run — put it back.
      {:error, _} -> resume(pid)
    end
  catch
    :exit, _ -> resume(pid)
  end

  @doc """
  Block until `pid` is between callbacks, then leave it suspended.

  Returns `:ok` whether or not the suspend succeeded — the caller is expected
  to terminate `pid` next either way.
  """
  @spec quiesce(pid(), timeout()) :: :ok
  def quiesce(pid, timeout \\ @default_timeout) when is_pid(pid) do
    if sys_process?(pid) do
      :sys.suspend(pid, timeout)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid, @default_timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  # `Task`s are `proc_lib` processes but have no `sys` loop, so `:sys.suspend`
  # on one blocks for the whole timeout and then exits. Skip anything that
  # isn't an OTP behaviour rather than paying that cost.
  defp sys_process?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$initial_call") do
          nil -> false
          {Task, _, _} -> false
          {Task.Supervised, _, _} -> false
          _ -> true
        end

      nil ->
        false
    end
  end
end
