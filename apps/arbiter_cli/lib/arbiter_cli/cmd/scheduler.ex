defmodule ArbiterCli.Cmd.Scheduler do
  @moduledoc """
  Board scheduler (autopilot) subcommand router:

      arb scheduler pause       — pause the autopilot (stop promoting Ready → Running)
      arb scheduler resume      — resume the autopilot
      arb scheduler status      — show the drain state and what is still in flight
      arb scheduler wait        — block until paused AND quiescent, then exit 0
          [--timeout SECS]      give up after SECS (default 3600) — exit 124
          [--interval SECS]     poll every SECS (default 10)

  A pause stops new *board* dispatches only. Work already under way — CI fix
  passes, MergeQueue conflict resolvers, ReviewGate rounds, explicit
  dispatches — keeps running so it can finish, and a server restart would
  kill it. `status` reports one of:

      running    — the autopilot is promoting; not a safe restart point
      draining   — paused, but work is still in flight (listed)
      quiescent  — paused and nothing in flight; safe to restart

  The restart workflow is `arb scheduler pause && arb scheduler wait`, then
  restart promptly: quiescence is a point in time, and a MergeQueue tick can
  start a resolver a moment later.

  `wait` exits 0 once quiescent, 2 if the scheduler is not paused (nothing to
  wait for — pause it first), 124 on timeout. Coordinator only.
  """

  alias ArbiterCli.{ArgParser, Client, Output, SchedulerState}

  @default_timeout_s 3600
  @default_interval_s 10

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      rest = Output.drop_json(argv)
      mode = Output.mode(argv)

      case rest do
        ["pause" | _] ->
          pause(mode)

        ["resume" | _] ->
          resume(mode)

        ["status" | _] ->
          status(mode)

        ["wait" | wait_argv] ->
          wait(wait_argv, mode)

        _ ->
          IO.puts(:stderr, "arb: unknown scheduler subcommand")
          IO.puts(:stderr, "Run `arb scheduler --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp pause(mode) do
    case Client.post("/api/scheduler/pause", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler paused. Work already in flight continues to completion.")
          IO.puts("Now: #{SchedulerState.headline(body)}")
          if SchedulerState.state(body) == "draining", do: emit_entries(body)
        end

      {:error, err} ->
        die(err)
    end
  end

  defp resume(mode) do
    case Client.post("/api/scheduler/resume", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler resumed. Autopilot is promoting Ready cards to Running.")
        end

      {:error, err} ->
        die(err)
    end
  end

  defp status(mode) do
    case SchedulerState.fetch() do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler is #{SchedulerState.headline(body)}.")
          emit_entries(body)
        end

      {:error, err} ->
        die(err)
    end
  end

  # ---- wait ------------------------------------------------------------------

  defp wait(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse_strict!(argv, "arb scheduler wait",
        strict: [timeout: :integer, interval: :integer]
      )

    timeout_ms = max(Keyword.get(opts, :timeout, @default_timeout_s), 0) * 1000
    interval_ms = max(Keyword.get(opts, :interval, @default_interval_s), 1) * 1000
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll(%{mode: mode, deadline: deadline, interval_ms: interval_ms, last: nil})
  end

  defp poll(ctx) do
    case SchedulerState.fetch() do
      {:ok, body} -> step(SchedulerState.state(body), body, ctx)
      {:error, err} -> die(err)
    end
  end

  defp step("quiescent", body, ctx),
    do: finish(body, ctx, 0, "Board scheduler is #{SchedulerState.headline(body)}.")

  defp step("running", body, ctx) do
    if ctx.mode == :json do
      IO.puts(Jason.encode!(body))
    else
      IO.puts(:stderr, "arb: error: the board scheduler is running — nothing to wait for")
      IO.puts(:stderr, "       hint: pause it first: `arb scheduler pause && arb scheduler wait`")
    end

    Output.halt(2)
  end

  defp step("unknown", body, ctx) do
    if ctx.mode == :json do
      IO.puts(Jason.encode!(body))
    else
      IO.puts(:stderr, "arb: error: #{SchedulerState.headline(body)}")
      IO.puts(:stderr, "       hint: upgrade the server, or check `arb worker list` by hand")
    end

    Output.halt(1)
  end

  defp step("draining", body, ctx) do
    ctx = report_progress(body, ctx)

    if System.monotonic_time(:millisecond) >= ctx.deadline do
      finish(body, ctx, 124, "Timed out: still #{SchedulerState.headline(body)}.")
    else
      ArbiterCli.Cmd.Start.sleep(ctx.interval_ms)
      poll(ctx)
    end
  end

  # Only print when the set of in-flight work changes, so a long drain
  # doesn't scroll the same list every interval.
  defp report_progress(body, %{mode: :text} = ctx) do
    fingerprint =
      Enum.map(SchedulerState.in_flight(body), &{&1["kind"], &1["task_id"], &1["registry_key"]})

    if fingerprint != ctx.last do
      IO.puts("Waiting: #{SchedulerState.headline(body)}")
      emit_entries(body)
    end

    %{ctx | last: fingerprint}
  end

  defp report_progress(_body, ctx), do: ctx

  defp finish(body, ctx, code, text) do
    if ctx.mode == :json, do: IO.puts(Jason.encode!(body)), else: IO.puts(text)
    if code != 0, do: Output.halt(code)
  end

  defp emit_entries(body) do
    Enum.each(SchedulerState.entry_lines(body), &IO.puts("  " <> &1))
  end

  defp die(%Client.Error{kind: :http, body: body}) when is_map(body) do
    Output.die(get_in(body, ["error", "message"]) || inspect(body))
  end

  defp die(%Client.Error{message: msg}), do: Output.die(msg)
end
