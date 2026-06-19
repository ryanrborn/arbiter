defmodule ArbiterCli.Cmd.Polecat do
  @moduledoc """
  Polecat subcommand router:

      arb polecat list             — list active polecats with status + step
      arb polecat show <bead-id>   — full snapshot incl. recent Claude output
      arb polecat log <bead-id>    — full uncapped durable transcript (audit)
      arb polecat stop <bead-id>   — terminate a running polecat cleanly

  Use `arb dispatch` to start a polecat in the first place.

  `show` reports a live polecat's full snapshot when one is running. When no
  live polecat exists for the bead it falls back to the most recent historical
  run (status, started/completed times, failure reason, and any retained
  output), so finished or exited runs stay inspectable. `show`'s output is the
  bounded UI tail (capped); `log` returns the **full, uncapped** transcript of
  the bead's most recent run from the durable on-disk store — the audit source
  of record, retaining every line however long the run.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["list" | _] -> list(mode)
        ["ls" | _] -> list(mode)
        ["show", bead_id | _] -> show(bead_id, mode)
        ["show" | _] -> Output.die("polecat show requires: <bead-id>")
        ["log", bead_id | _] -> log(bead_id, mode)
        ["log" | _] -> Output.die("polecat log requires: <bead-id>")
        ["stop", bead_id | _] -> stop(bead_id, mode)
        ["stop" | _] -> Output.die("polecat stop requires: <bead-id>")
        [] -> Output.die("polecat requires a subcommand: `list`, `show`, `log`, or `stop`")
        [unknown | _] -> Output.die("unknown polecat subcommand: #{unknown}")
      end
    end
  end

  defp list(mode) do
    case Client.get("/api/polecats") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(bead_id, mode) do
    case Client.get("/api/polecats/#{bead_id}") do
      {:ok, snap} -> emit_show(snap, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp log(bead_id, mode) do
    case Client.get("/api/polecats/#{bead_id}/log") do
      {:ok, %{"data" => data}} -> emit_log(data, mode)
      {:ok, payload} -> emit_log(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp stop(bead_id, mode) do
    case Client.post("/api/polecats/#{bead_id}/stop", %{}) do
      {:ok, payload} -> emit_stop(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- render ---------------------------------------------------------

  defp emit_show(snap, :json), do: IO.puts(Jason.encode!(snap))

  defp emit_show(snap, :text) do
    if snap["source"] == "history" do
      IO.puts("(no live worker — showing most recent historical run)")
    end

    IO.puts("Issue:       #{snap["bead_id"]}")
    IO.puts("Status:     #{snap["status"]}")
    # A claude-driven worker has no ticking workflow step; show the live
    # activity derived from its stream instead of a frozen step. See bd-c919xj.
    if snap["claude_session"] do
      IO.puts("Activity:   #{activity_label(snap)}")
    else
      IO.puts("Step:       #{snap["current_step"]}")
    end

    IO.puts("Repo:        #{snap["repo"]}")
    IO.puts("Started:    #{snap["started_at"]}")
    if snap["completed_at"], do: IO.puts("Completed:  #{snap["completed_at"]}")
    if snap["exit_status"], do: IO.puts("Exit:       #{snap["exit_status"]}")
    if snap["result"], do: IO.puts("Result:     #{snap["result"]}")
    if snap["failure_reason"], do: IO.puts("Failure:    #{snap["failure_reason"]}")

    case snap["output_lines"] || [] do
      [] ->
        IO.puts("\n(no output lines captured)")

      lines ->
        IO.puts("\nOutput (#{length(lines)} lines, oldest first):")
        Enum.each(lines, fn line -> IO.puts("  | #{line}") end)
    end
  end

  defp emit_log(data, :json), do: IO.puts(Jason.encode!(data))

  defp emit_log(data, :text) do
    IO.puts("Issue:       #{data["bead_id"]}")
    IO.puts("Run:        #{data["run_id"]}")
    IO.puts("Transcript: #{data["path"]}")

    cond do
      data["exists"] == false ->
        IO.puts("\n(no durable transcript on disk for this run)")

      (data["lines"] || []) == [] ->
        IO.puts("\n(durable transcript is empty)")

      true ->
        lines = data["lines"]
        IO.puts("\nFull transcript (#{length(lines)} lines, oldest first):")
        Enum.each(lines, fn line -> IO.puts("  | #{line}") end)
    end
  end

  defp emit_stop(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_stop(payload, :text) do
    IO.puts("Stopped worker for issue #{payload["bead_id"]}.")
  end

  defp emit_list(list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text) do
    IO.puts("(no active workers)")
  end

  defp emit_list(list, :text) do
    IO.puts("Active workers (#{length(list)}):")

    Enum.each(list, fn p ->
      step =
        if p["claude_session"],
          do: "activity=#{activity_label(p)}",
          else: "step=#{p["current_step"]}"

      model_part = if p["model"], do: "  model=#{p["model"]}", else: ""
      cost_part = format_cost(p["cost_usd"])

      IO.puts(
        "  #{p["bead_id"]}  status=#{p["status"]}  #{step}  repo=#{p["repo"]}  started=#{p["started_at"]}#{model_part}#{cost_part}"
      )
    end)
  end

  defp format_cost(nil), do: ""
  defp format_cost(cost) when cost <= 0, do: ""
  defp format_cost(cost) when is_number(cost), do: "  cost=$#{Float.round(cost / 1, 4)}"

  # The JSON API exposes a claude-driven worker's live activity as a map
  # (%{"label", "kind", "since"}) or null; render its label, falling back to a
  # plain "working" until the first stream event lands. See bd-c919xj.
  defp activity_label(snap) do
    case snap["activity"] do
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> "working"
    end
  end
end
