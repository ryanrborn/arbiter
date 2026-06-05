defmodule Arbiter.SingleInstance do
  @moduledoc """
  Single-instance guard for boot reconciliation.

  Replaces the former Postgres session-advisory-lock with a two-layer guard:

  1. **In-process layer**: an ETS table prevents two `SingleInstance` GenServers
     within the same Erlang VM from both thinking they're primary. This covers
     duplicate `iex -S mix` or test scenarios.
  2. **Cross-process layer**: a PID-file in the data directory
     (`~/.arbiter/arbiter.pid`) prevents two separate OS processes from both
     claiming primary. A stale file (left by a crash) is detected by checking
     whether the recorded OS PID is still alive.

  SQLite serialises writes itself, so the guard is "lightweight" compared to
  the former Postgres advisory lock — it exists solely to prevent a second
  concurrent server from sweeping the primary's live `:running` polecat runs
  as orphans during boot reconciliation.

  The lock is automatically released (file removed + ETS entry deleted) on a
  clean shutdown. A hard kill leaves a stale PID file; the next boot detects
  the stale PID via the liveness check.

  ## Test API

  Accepts `:name`, `:lock_file` (overrides the default lock-file path), and
  `:lock_key` (integer, maps to `/tmp/arbiter_lock_{key}.pid` — for unit tests
  that need multiple competing guards without touching real data directories).

  Relates to bd-9rouwh (the original gate) and bd-tbslcb (this SQLite migration).
  """

  use GenServer

  require Logger

  @lock_file_name "arbiter.pid"
  @ets_table :arbiter_single_instance_locks

  @doc """
  Start the single-instance guard.

  Options:
    * `:name` — registered name (defaults to `__MODULE__`)
    * `:lock_file` — override the lock-file path (primarily for tests)
    * `:lock_key` — integer key; maps to a temp-dir lock file (for tests)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Whether this node holds the single-instance lock (is the primary).

  Returns `false` when the guard is not running, so a caller in the boot path
  fails safe — a missing guard must never green-light the destructive sweep.
  """
  @spec primary?(GenServer.server()) :: boolean()
  def primary?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> GenServer.call(pid, :primary?)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_ets_table()
    lock_file = resolve_lock_file(opts)
    primary? = try_acquire(lock_file)
    {:ok, %{lock_file: lock_file, primary?: primary?}}
  end

  @impl true
  def handle_call(:primary?, _from, state), do: {:reply, state.primary?, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lock_file: lock_file, primary?: true}) do
    :ets.delete(@ets_table, lock_file)
    File.rm(lock_file)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---- private ----------------------------------------------------------------

  defp try_acquire(lock_file) do
    my_os_pid = os_pid()

    # In-process guard: prevent two GenServers in the same Erlang VM from both
    # claiming the same lock file (covers tests and duplicate iex boots).
    case :ets.insert_new(@ets_table, {lock_file, self()}) do
      false ->
        Logger.warning(
          "SingleInstance: in-process lock already held; running as SECONDARY " <>
            "(boot reconciliation disabled)"
        )

        false

      true ->
        case File.read(lock_file) do
          {:ok, existing} ->
            existing_pid = String.trim(existing)

            if pid_alive?(existing_pid) do
              # Cross-process: another OS process holds the file. Remove our
              # ETS entry (we won't own the file) and report secondary.
              :ets.delete(@ets_table, lock_file)

              Logger.warning(
                "SingleInstance: lock held by PID #{existing_pid}; running as SECONDARY " <>
                  "(boot reconciliation disabled)"
              )

              false
            else
              # Stale file from a dead process — claim it.
              write_lock(lock_file, my_os_pid)
            end

          {:error, :enoent} ->
            write_lock(lock_file, my_os_pid)

          {:error, reason} ->
            :ets.delete(@ets_table, lock_file)

            Logger.warning(
              "SingleInstance: could not read lock file (#{reason}); running as SECONDARY " <>
                "(boot reconciliation disabled)"
            )

            false
        end
    end
  end

  defp write_lock(lock_file, pid_str) do
    File.mkdir_p!(Path.dirname(lock_file))

    case File.write(lock_file, pid_str) do
      :ok ->
        Logger.info(
          "SingleInstance: acquired lock file #{lock_file}; this is the PRIMARY instance"
        )

        true

      {:error, reason} ->
        :ets.delete(@ets_table, lock_file)

        Logger.warning(
          "SingleInstance: could not write lock file (#{reason}); running as SECONDARY " <>
            "(boot reconciliation disabled)"
        )

        false
    end
  end

  defp pid_alive?(pid_str) do
    case :os.type() do
      {:unix, _} ->
        case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      _ ->
        true
    end
  end

  defp os_pid, do: :os.getpid() |> to_string()

  defp resolve_lock_file(opts) do
    cond do
      file = Keyword.get(opts, :lock_file) ->
        file

      key = Keyword.get(opts, :lock_key) ->
        Path.join(System.tmp_dir!(), "arbiter_lock_#{key}.pid")

      true ->
        data_dir = Application.get_env(:arbiter, :data_dir, Path.expand("~/.arbiter"))
        Path.join(data_dir, @lock_file_name)
    end
  end

  defp ensure_ets_table do
    if :ets.info(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError ->
      # Race: another process already created the table
      :ok
  end
end
