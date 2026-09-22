defmodule Arbiter.ProcessTeardown do
  @moduledoc """
  Stop a supervised process without interrupting whatever it is doing.

  `DynamicSupervisor.terminate_child/2` sends a bare `Process.exit(child,
  :shutdown)`. None of Arbiter's per-workspace patrols, machines or queues
  trap exits, so that signal kills them the instant it arrives — including
  while they are parked inside an `Ecto` query or transaction. (`Arbiter.Worker`
  has trapped exits since bd-aje6fj, so a supervisor shutdown reaches its
  `terminate/2`; everything below still applies to the rest.)

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
  Stop `pid` between callbacks, running its `terminate/2`.

  The difference from the exit signal a supervisor sends — and from the
  `Process.exit(pid, :shutdown)` a caller reaches for by hand — is that an
  exit signal skips `terminate/2` entirely on a process that does not trap
  exits. For `Arbiter.Worker` that callback is the only thing that SIGKILLs
  the agent's OS process and its descendants (bd-bmmj4w); the worker traps
  exits now (bd-aje6fj), but this helper takes any owner, and skipping the
  callback on one that does not trap leaves a live `claude` — and whatever it
  spawned — running with its cwd inside a workspace the caller is about to
  reclaim. `GenServer.stop/3` goes through the `sys` terminate path
  instead, which a suspended `gen_*` still handles, so the quiesce still
  holds.

  Always returns `:ok`. A process that will not stop within `timeout` is
  resumed and **left alive**: the caller can see that with `Process.alive?/1`
  and decide what to do, and killing it here would skip `terminate/2` for a
  second time.
  """
  @spec stop(pid(), timeout()) :: :ok
  def stop(pid, timeout \\ @default_timeout) when is_pid(pid) do
    if sys_process?(pid) do
      quiesce(pid, timeout)

      try do
        GenServer.stop(pid, :shutdown, timeout)
        :ok
      catch
        # Not a `gen_*` after all, already gone, or it would not stop in time.
        :exit, _ -> resume(pid)
      end
    else
      # No `sys` loop, so there is no `terminate/2` to preserve and
      # `GenServer.stop/3` would only block for the whole timeout before
      # timing out. One that traps exits and declines to stop stays alive, as
      # above.
      Process.exit(pid, :shutdown)
      :ok
    end
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
  #
  # The classification has to come from `Process.info(pid, :initial_call)`, the
  # entry point the VM recorded at spawn: `:gen_server`, `:gen_statem`,
  # `:gen_event`, `Supervisor`, `DynamicSupervisor` and `Agent` all go through
  # `:proc_lib.init_p/5`, while a `Task` is `{Task.Supervised, :reply | :noreply,
  # _}` and a bare `spawn` is its own MFA.
  #
  # The `$initial_call` *dictionary* entry looks like it would work and does
  # not: `Task.Supervised.get_initial_call/1` writes the user's own MFA there,
  # exactly the shape a `GenServer` gets, so a Task is indistinguishable — and
  # `Agent` writes an anonymous fun, so it would be misread the other way. It is
  # also written by the new process itself, which makes reading it a race
  # against that process's startup.
  defp sys_process?(pid) do
    Process.info(pid, :initial_call) == {:initial_call, {:proc_lib, :init_p, 5}}
  end
end
