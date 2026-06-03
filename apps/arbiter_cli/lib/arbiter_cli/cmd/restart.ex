defmodule ArbiterCli.Cmd.Restart do
  @moduledoc """
  `arb restart [--timeout SECONDS] [--json]` — restart the Phoenix server so
  freshly-merged code is loaded.

  Dev code-reload covers most edits, but a clean restart also re-runs the boot
  reconciler (`Arbiter.Polecats.ReconcileGuard`), which fails any orphaned
  `:running` polecat runs left behind by the previous node — something a hot
  reload never does. Pairs with `arb start` (boot the stack if down) and
  `arb update` (pull + migrate).

  What it does:

    1. **Stop the running server.** Find the OS process listening on the API
       port (derived from `ARB_HOST`) via `lsof` and send it `SIGTERM` for a
       clean BEAM shutdown. If the port hasn't freed within a grace window,
       escalate to `SIGKILL`.
    2. **Wait for the port to free**, so the fresh server doesn't trip over an
       "address already in use".
    3. **Start Phoenix** detached (reusing `arb start`'s launcher), inheriting
       this process's environment so `GITHUB_TOKEN` and other secrets the
       tracker needs carry through to the new server.
    4. **Wait for green.** Poll `arb doctor` until every check passes (or the
       timeout elapses), then print the status report.

  Postgres is assumed already up — this restarts only Phoenix. If the whole
  stack is down, use `arb start` instead (which also boots Postgres); restart
  will still happily start Phoenix when nothing is running.

  ## Exit codes

    * `0` — Phoenix restarted and the stack is green.
    * `1` — the old server couldn't be stopped, Phoenix didn't come back green
      within the timeout, or a prerequisite (project root) was missing.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Start, Output}

  @switches [json: :boolean, timeout: :integer]

  # How long to wait for the freshly-started stack to go green. A cold
  # `mix phx.server` may recompile first, so the default is generous.
  @default_timeout_s 60
  @poll_interval_ms 500

  # Independent, shorter budget for the old server to release the port after
  # SIGTERM before we escalate to SIGKILL.
  @stop_timeout_ms 15_000

  # Fallback API port when ARB_HOST carries no explicit one (matches Client's
  # default of http://127.0.0.1:4848).
  @default_port 4848

  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000

    root =
      case Start.project_root() do
        {:ok, dir} ->
          dir

        :error ->
          Output.die(
            "could not locate the Arbiter project root (no compose.yml found)",
            "Set ARB_HOME to your Arbiter checkout, or run `arb restart` from inside it."
          )
      end

    port = api_port()
    was_running = Doctor.reachable?()

    stop_action = stop_phoenix(port)
    start_action = Start.start_phoenix(root)

    actions = [stop_action, start_action]

    case Start.wait_until_green(Start.attempts_for(timeout_ms)) do
      :ok -> emit_restarted(mode, actions, was_running)
      :timeout -> emit_timeout(mode, actions, timeout_ms)
    end
  end

  # ---- stop --------------------------------------------------------------

  # Find the listener on `port`, signal it, and wait for the port to free.
  # Returns a `{:phoenix_stop, status, detail}` action tuple.
  defp stop_phoenix(port) do
    case listeners(port) do
      [] ->
        # Nothing to stop — a restart of a down server is just a start.
        {:phoenix_stop, :not_running, nil}

      pids ->
        Start.log_text("Stopping Phoenix on port #{port} (SIGTERM to #{Enum.join(pids, ", ")})…")
        signal(pids, "TERM")

        case wait_port_free(port, attempts_for(@stop_timeout_ms)) do
          :ok ->
            {:phoenix_stop, :stopped, pids}

          :timeout ->
            escalate(port, pids)
        end
    end
  end

  # SIGTERM didn't free the port in time — re-read the listeners (the original
  # pids may already be gone) and SIGKILL whatever remains.
  defp escalate(port, original_pids) do
    remaining = listeners(port)
    Start.log_text("Phoenix did not exit cleanly; escalating to SIGKILL…")
    if remaining != [], do: signal(remaining, "KILL")

    case wait_port_free(port, attempts_for(@stop_timeout_ms)) do
      :ok ->
        {:phoenix_stop, :killed, original_pids}

      :timeout ->
        Output.die(
          "could not free port #{port}; a process is still listening",
          "Find and stop it manually (e.g. `lsof -ti tcp:#{port}` then `kill`)."
        )
    end
  end

  # Pids of processes LISTENing on `port`, via `lsof -t`. lsof exits non-zero
  # when nothing matches, which we treat as "no listeners".
  defp listeners(port) do
    case run_cmd("lsof", ["-ti", "tcp:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
      {out, 0} -> parse_pids(out)
      {_out, _nonzero} -> []
    end
  rescue
    e in ErlangError ->
      # System.cmd raises when the executable isn't found (:enoent).
      Output.die(
        "could not run lsof: #{inspect(e.original)}",
        "Install lsof (it's used to find the running server) and ensure it's on your PATH."
      )
  end

  defp parse_pids(out) do
    out
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
  end

  defp signal(pids, sig) do
    run_cmd("kill", ["-#{sig}" | pids], stderr_to_stdout: true)
  end

  defp wait_port_free(port, attempts_left) do
    cond do
      listeners(port) == [] ->
        :ok

      attempts_left <= 0 ->
        :timeout

      true ->
        sleep(@poll_interval_ms)
        wait_port_free(port, attempts_left - 1)
    end
  end

  # ---- output ------------------------------------------------------------

  defp emit_restarted(:json, actions, was_running) do
    IO.puts(
      Jason.encode!(%{
        was_running: was_running,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: Doctor.green?()
      })
    )
  end

  defp emit_restarted(:text, actions, _was_running) do
    IO.puts("")
    IO.puts(stop_summary(actions))
    IO.puts("Arbiter Phoenix restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  defp emit_timeout(:json, actions, timeout_ms) do
    IO.puts(
      Jason.encode!(%{
        was_running: nil,
        actions: action_payload(actions),
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: false,
        timed_out_after_s: div(timeout_ms, 1000)
      })
    )

    Output.halt(1)
  end

  defp emit_timeout(:text, actions, timeout_ms) do
    IO.puts("")
    IO.puts(stop_summary(actions))
    IO.puts("Arbiter Phoenix did not come back up within #{div(timeout_ms, 1000)}s.")
    IO.puts("Last status:")
    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for Phoenix startup output.")
    Output.halt(1)
  end

  defp stop_summary(actions) do
    case List.keyfind(actions, :phoenix_stop, 0) do
      {:phoenix_stop, :not_running, _} -> "No running server found — started a fresh one.\n"
      {:phoenix_stop, :stopped, _} -> "Stopped the previous server (SIGTERM).\n"
      {:phoenix_stop, :killed, _} -> "Force-stopped the previous server (SIGKILL).\n"
      _ -> ""
    end
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end

  # ---- port --------------------------------------------------------------

  # The API port Phoenix listens on, parsed from ARB_HOST (via Client).
  defp api_port do
    case URI.parse(Client.base_url()) do
      %URI{port: port} when is_integer(port) -> port
      _ -> @default_port
    end
  end

  # ---- injectable seams --------------------------------------------------
  #
  # Route through `arb start`'s seams so a single `:bd2_cmd_runner` /
  # `:bd2_sleep` test stub covers both the stop (lsof/kill) and start phases.

  defp run_cmd(cmd, args, opts), do: Start.run_cmd(cmd, args, opts)
  defp sleep(ms), do: Start.sleep(ms)

  # Count-based attempt budget, mirroring Start.attempts_for/1 but against the
  # stop grace window rather than the green-wait timeout.
  defp attempts_for(timeout_ms), do: div(timeout_ms, @poll_interval_ms) + 1
end
