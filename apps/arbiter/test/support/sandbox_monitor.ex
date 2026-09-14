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
  stops the owning `DBConnection.Ownership.Proxy`.

  Nothing in the default output marks that as a problem: it is one `[error]`
  line in a suite that logs thousands of expected warnings, and the damage
  lands somewhere else entirely. That is why it reached CI as an
  unreproducible cascade of failures in files the branch never touched.

  ## Two classes, only one of which is a bug

  * **mid-test** — a live test's connection is pulled out from under it. Every
    later query in that test raises `DBConnection.OwnershipError`, which call
    sites routinely swallow into a misleading `:not_found` (e.g.
    `Arbiter.MCP.Tools.fetch_graph/2` turns it into "graph ... not found"), and
    `async: false` tests take every other process in the VM with them because
    shared mode reverts to `:manual`. This is a real bug in whatever killed the
    process; it **fails the run**.

  * **teardown** — the process died after its test's process had already
    exited, e.g. `Phoenix.LiveViewTest` killing a LiveView that still had a
    queued PubSub echo to handle when the test ended (ExUnit exits the test
    process with `:shutdown`, and `Phoenix.LiveView.Channel` does not trap
    exits). The owner is the test that just finished and is about to be torn
    down anyway, so no test observes the loss. It is still reported, because a
    dropped connection is never free — the pool has to reconnect — but it does
    not fail the run.

  The discriminator is simply whether any test process registered with
  `track/3` was still alive when the disconnect fired.
  """

  @handler_id :arbiter_sandbox_monitor
  @running :arbiter_sandbox_monitor_running
  @incidents :arbiter_sandbox_monitor_incidents

  @doc """
  Install the monitor. Call once, from `test_helper.exs`, after `ExUnit.start/0`.

  Idempotent: an umbrella `mix test` runs every app's `test_helper.exs` in the
  same VM.
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
    end

    # Once per app suite: each app reports (and clears) its own incidents.
    ExUnit.after_suite(&report/1)

    :ok
  end

  @doc "Record that `pid` is running `module`/`name`. Called from the sandbox setup."
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
      String.contains?(text, "exited")
  end

  # `{pid, module, name, alive?}` for every test registered with the sandbox
  # right now. `alive?` is the whole discriminator: ExUnit only runs `on_exit`
  # callbacks once the test process is gone, so a dead one means the disconnect
  # landed in teardown rather than in the middle of a test.
  defp running_tests do
    case :ets.whereis(@running) do
      :undefined ->
        []

      _ ->
        for {pid, mod, name} <- :ets.tab2list(@running) do
          {pid, mod, name, Process.alive?(pid)}
        end
    end
  end

  defp message_text({:string, chardata}), do: IO.chardata_to_string(chardata)

  defp message_text({format, args}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp message_text(other), do: inspect(other)

  @doc """
  Which class an incident's registered-test snapshot belongs to.

  `:mid_test` if any of those test processes was still alive when the
  disconnect fired — ExUnit only runs `on_exit` callbacks once the test process
  is gone, so a live one means a running test just lost its connection.
  """
  @spec classify([{pid(), module(), String.t(), boolean()}]) :: :mid_test | :teardown
  def classify(running) do
    if Enum.any?(running, fn {_pid, _mod, _name, alive?} -> alive? end),
      do: :mid_test,
      else: :teardown
  end

  @doc "Every incident recorded so far."
  def incidents do
    case :ets.whereis(@incidents) do
      :undefined -> []
      _ -> :ets.tab2list(@incidents)
    end
  end

  @doc "Drop a single recorded incident (used by the monitor's own tests)."
  def forget(incident) do
    if :ets.whereis(@incidents) != :undefined do
      :ets.delete_object(@incidents, incident)
    end

    :ok
  end

  @doc false
  def report(_results) do
    incidents = :ets.tab2list(@incidents)
    :ets.delete_all_objects(@incidents)

    case incidents do
      [] ->
        :ok

      _ ->
        {mid_test, teardown} =
          Enum.split_with(incidents, fn {:incident, _text, running} ->
            classify(running) == :mid_test
          end)

        IO.puts(:stderr, format_report(mid_test, teardown))

        if mid_test != [] do
          System.at_exit(fn
            0 -> exit({:shutdown, 1})
            _ -> :ok
          end)
        end
    end
  end

  defp format_report(mid_test, teardown) do
    """

    ============ SANDBOX CONNECTION KILLED (bd-5scl0c) ============
    #{length(mid_test)} mid-test, #{length(teardown)} in teardown.

    A process was killed while holding a checkout on the single shared
    sandbox connection. That drops the physical SQLite connection, rolls
    back the in-flight sandbox transaction and destroys the owning
    DBConnection.Ownership.Proxy.

    Fix whatever kills the process — do not raise timeouts. Anything
    stopped with `Process.exit/2` or `DynamicSupervisor.terminate_child/2`
    must be quiesced first; `Arbiter.ProcessTeardown.stop_child/3` does
    that with `:sys.suspend/2`.
    #{section("MID-TEST (fails the run) — a live test lost its connection", mid_test)}#{section("TEARDOWN (reported only) — the owning test had already exited", teardown)}
    ===============================================================
    """
  end

  defp section(_title, []), do: ""

  defp section(title, incidents) do
    body =
      incidents
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{:incident, text, running}, i} ->
        tests =
          case running do
            [] ->
              "      (no test was registered with the sandbox at that moment)"

            names ->
              Enum.map_join(names, "\n", fn {pid, mod, name, alive?} ->
                "      [#{if alive?, do: "alive", else: "exited"}] " <>
                  "#{inspect(mod)} #{name} (#{inspect(pid)})"
              end)
          end

        "  #{i}. #{text}\n     registered tests at that moment:\n#{tests}"
      end)

    "\n  #{title}:\n\n#{body}\n"
  end
end
