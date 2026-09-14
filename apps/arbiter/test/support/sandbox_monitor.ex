defmodule Arbiter.Test.SandboxMonitor do
  @moduledoc """
  Detects — and attributes — sandbox connection kills during the test suite
  (bd-5scl0c).

  The whole suite shares **one** physical SQLite connection (`pool_size: 1`,
  see `config/test.exs`). If any process is killed, or crashes, while it holds
  a checkout on that connection, DBConnection has to assume the connection is
  in an unknown state. It logs

      Exqlite.Connection (#PID<...>) disconnected:
        ** (DBConnection.ConnectionError) client #PID<...> exited

  drops the physical connection — rolling back the sandbox transaction — and
  stops the owning `DBConnection.Ownership.Proxy`. From there the owning test
  has no sandbox at all: later queries raise `DBConnection.OwnershipError`
  ("cannot find ownership process"), which call sites routinely swallow into a
  misleading `:not_found`, and `async: false` tests (which run in *shared*
  mode) take every other process in the VM down with them.

  The damage lands in whatever test happens to be running, not in the test
  that caused it, which is why this showed up in CI as an unreproducible
  cascade of failures in files the branch never touched. Nothing in the
  default output marks it: the disconnect is a single `[error]` line in a
  suite that logs thousands of expected warnings.

  So: watch for the signature, record the tests that were running when it
  fired, print a report at the end of the suite, and fail the run. A silent
  corrupted connection is strictly worse than a loud failure.
  """

  @handler_id :arbiter_sandbox_monitor
  @running :arbiter_sandbox_monitor_running
  @incidents :arbiter_sandbox_monitor_incidents

  @signature "exited"

  @doc """
  Install the monitor. Call once, from `test_helper.exs`, after `ExUnit.start/0`.
  """
  def install do
    if :ets.whereis(@running) == :undefined do
      :ets.new(@running, [:public, :named_table, :set, write_concurrency: true])
      :ets.new(@incidents, [:public, :named_table, :duplicate_bag, write_concurrency: true])

      :logger.add_handler(@handler_id, __MODULE__, %{
        level: :all,
        filter_default: :log,
        filters: []
      })

      ExUnit.after_suite(&report/1)
    end

    :ok
  end

  @doc "Record that `pid` is running `module`/`name` (called from the sandbox setup)."
  def track(pid, module, name) do
    if :ets.whereis(@running) != :undefined do
      :ets.insert(@running, {pid, module, name})
    end

    :ok
  end

  @doc "Stop tracking `pid`."
  def untrack(pid) do
    if :ets.whereis(@running) != :undefined do
      :ets.delete(@running, pid)
    end

    :ok
  end

  @doc false
  # :logger handler callback.
  def log(%{msg: msg}, _config) do
    text = message_text(msg)

    if disconnect?(text) do
      :ets.insert(@incidents, {:incident, text, running_tests()})
    end

    :ok
  rescue
    # A logger handler must never take the suite down with it.
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp disconnect?(text) do
    String.contains?(text, "DBConnection.ConnectionError") and
      String.contains?(text, "client #PID") and
      String.contains?(text, @signature)
  end

  defp running_tests do
    case :ets.whereis(@running) do
      :undefined ->
        []

      _ ->
        for {pid, mod, name} <- :ets.tab2list(@running),
            do: "#{inspect(mod)} #{name} (#{inspect(pid)})"
    end
  end

  defp message_text({:string, chardata}), do: IO.chardata_to_string(chardata)

  defp message_text({format, args}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp message_text(other), do: inspect(other)

  @doc false
  def report(_results) do
    case :ets.tab2list(@incidents) do
      [] ->
        :ok

      incidents ->
        IO.puts(:stderr, format_report(incidents))

        System.at_exit(fn
          0 -> exit({:shutdown, 1})
          _ -> :ok
        end)
    end
  end

  defp format_report(incidents) do
    body =
      incidents
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{:incident, text, running}, i} ->
        tests =
          case running do
            [] -> "    (no test was registered with the sandbox at that moment)"
            names -> Enum.map_join(names, "\n", &"    #{&1}")
          end

        "  #{i}. #{text}\n  running at the time:\n#{tests}"
      end)

    """

    ================ SANDBOX CONNECTION KILLED (bd-5scl0c) ================
    #{length(incidents)} process(es) were killed while holding a checkout on the
    shared sandbox connection. Each one silently dropped the single physical
    SQLite connection, rolled back the in-flight sandbox transaction and
    destroyed the owning DBConnection.Ownership.Proxy — so unrelated tests can
    fail with `DBConnection.OwnershipError`, "could not lookup Ecto repo" or a
    bogus `:not_found`.

    Fix the process that dies, do not raise timeouts. Anything killed with
    `Process.exit/2`, `DynamicSupervisor.terminate_child/2` or a supervisor
    shutdown must be quiesced first (see `Arbiter.ProcessTeardown.stop_child/3`).

    #{body}
    =======================================================================
    """
  end
end
