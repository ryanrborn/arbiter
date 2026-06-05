defmodule ArbiterCli.Cmd.Restart do
  @moduledoc """
  `arb restart [--timeout SECONDS] [--json]` — restart the Phoenix server so
  freshly-merged code is loaded.

  Dev code-reload covers most edits, but a clean restart also re-runs the boot
  reconciler (`Arbiter.Polecats.ReconcileGuard`), which fails any orphaned
  `:running` polecat runs left behind by the previous node — something a hot
  reload never does. Pairs with `arb start` (boot the stack if down) and
  `arb update` (pull latest main, then restart — it reuses `perform/2` below).

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

  @switches [json: :boolean, timeout: :integer, force: :boolean]

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
    force = opts[:force] || false

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

    guard_active_polecats!(force)

    case perform(root, timeout_ms) do
      {:ok, actions, was_running} -> emit_restarted(mode, actions, was_running)
      {:timeout, actions, _was_running} -> emit_timeout(mode, actions, timeout_ms)
    end
  end

  @doc """
  Stop the running Phoenix, start a fresh one, and wait up to `timeout_ms` for
  the stack to go green.

  Returns `{result, actions, was_running}` where `result` is `:ok` or
  `:timeout`, `actions` is the `[{:phoenix_stop, _, _}, {:phoenix, :ok, _}]`
  list, and `was_running` records whether the API was reachable before the
  bounce. Shared with `arb update`, which runs a `git pull` first and then
  reuses this to load the freshly-merged code — so the two commands have one
  definition of "bounce Phoenix".
  """
  @spec perform(String.t(), non_neg_integer()) :: {:ok | :timeout, list(), boolean()}
  def perform(root, timeout_ms) do
    port = api_port()
    was_running = Doctor.reachable?()

    stop_action = stop_phoenix(port)
    start_action = Start.start_phoenix(root)

    actions = [stop_action, start_action]

    case Start.wait_until_green(Start.attempts_for(timeout_ms)) do
      :ok -> {:ok, actions, was_running}
      :timeout -> {:timeout, actions, was_running}
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

  # Pids of processes LISTENing on `port`. Tries lsof first; if lsof is absent
  # (:enoent) falls back to `ss` (iproute2, standard on modern Linux), then
  # `pgrep -f "phx.server"` as a last resort. Returns [] when nothing is found
  # or when every tool is unavailable.
  defp listeners(port) do
    case run_cmd("lsof", ["-ti", "tcp:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
      {out, 0} -> parse_pids(out)
      {_out, _nonzero} -> []
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        listeners_without_lsof(port)
      else
        Output.die(
          "could not run lsof: #{inspect(e.original)}",
          "Ensure lsof is on your PATH, or it will be auto-skipped if absent."
        )
      end
  end

  # lsof is absent; try ss (iproute2) then pgrep as ordered fallbacks.
  defp listeners_without_lsof(port) do
    pids = listeners_via_ss(port)
    if pids != [], do: pids, else: listeners_via_pgrep()
  end

  # `ss -Htlnp sport = :<port>` emits lines like:
  #   LISTEN 0 128 0.0.0.0:4848 0.0.0.0:* users:(("beam.smp",pid=1234,fd=20))
  # Extract every `pid=\d+` match.
  defp listeners_via_ss(port) do
    case run_cmd("ss", ["-Htlnp", "sport", "=", ":#{port}"], stderr_to_stdout: true) do
      {out, _} ->
        ~r/pid=(\d+)/
        |> Regex.scan(out)
        |> Enum.map(fn [_, pid] -> pid end)
        |> Enum.uniq()
    end
  rescue
    _ -> []
  end

  # Fallback when both lsof and ss are unavailable: find mix phx.server processes
  # by name. Not port-specific, but good enough when only one server runs locally.
  defp listeners_via_pgrep do
    case run_cmd("pgrep", ["-f", "phx.server"], stderr_to_stdout: true) do
      {out, 0} -> parse_pids(out)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_pids(out) do
    out
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
  end

  defp signal(pids, sig) do
    run_cmd("kill", ["-#{sig}" | pids], stderr_to_stdout: true)
  end

  # Poll until the port accepts no connection (i.e. the old server released it).
  # Uses a TCP connect probe instead of lsof so it works without any external
  # tool, and avoids repeated lsof/ss invocations on every poll tick.
  defp wait_port_free(port, attempts_left) do
    cond do
      port_free?(port) ->
        :ok

      attempts_left <= 0 ->
        :timeout

      true ->
        sleep(@poll_interval_ms)
        wait_port_free(port, attempts_left - 1)
    end
  end

  # Returns true when nothing answers on `port`. The `:bd2_port_check` seam lets
  # tests override this without shelling out or opening real sockets.
  defp port_free?(port) do
    case Process.get(:bd2_port_check) do
      fun when is_function(fun, 1) ->
        fun.(port)

      _ ->
        case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            false

          {:error, _} ->
            true
        end
    end
  end

  # ---- active-work guard -------------------------------------------------

  # Statuses that mean a Claude acolyte is actively spending tokens and has an
  # outpost (worktree) that would be abandoned if the server is bounced now.
  @active_statuses ~w(running awaiting awaiting_tribunal awaiting_review)

  @doc """
  Abort with a helpful error when any polecats are actively working, unless
  `force` is true. Safe to call when the server is down: a connection error
  means no polecats can be running.

  Shared with `arb update` (deploy) and `arb install-service`.
  """
  @spec guard_active_polecats!(boolean()) :: :ok
  def guard_active_polecats!(force) do
    case Client.get("/api/polecats") do
      {:ok, %{"data" => polecats}} ->
        active =
          Enum.filter(polecats, fn p ->
            p["status"] in @active_statuses
          end)

        if active != [] and not force do
          list =
            Enum.map_join(active, "\n", fn p ->
              "  #{p["bead_id"]}  (#{p["status"]})"
            end)

          Output.die(
            "#{length(active)} acolyte(s) are actively working",
            "Restarting now kills in-flight work and abandons their outposts and token spend.\n" <>
              "Active:\n" <>
              list <>
              "\nPass --force to override."
          )
        end

      _ ->
        # Server unreachable or unexpected response — no active polecats possible.
        :ok
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
