defmodule ArbiterCli.Cmd.Worker do
  @moduledoc """
  Worker subcommand router:

      arb worker list             — list active workers with status + step
      arb worker show <task-id>   — full snapshot incl. recent Claude output
      arb worker runs <task-id>   — list every historical run for the task
      arb worker log <task-id>    — full uncapped durable transcript (audit)
      arb worker stop <task-id>   — terminate a running worker cleanly
      arb worker review <task-id> [--repo <repo>] [--model <name>] — spawn a review worker

  Use `arb dispatch` to start a worker in the first place.

  `show` reports a live worker's full snapshot when one is running. When no
  live worker exists for the task it falls back to the most recent historical
  run (status, started/completed times, failure reason, and any retained
  output), so finished or exited runs stay inspectable. `runs` lists *every*
  recorded run for the task (main, review, and impl workers) newest-first —
  use it to see how many times a task was worked, by whom, and the outcome of
  each. `show`'s output is the bounded UI tail (capped); `log` returns the
  **full, uncapped** transcript of the task's most recent run from the durable
  on-disk store — the audit source of record, retaining every line however
  long the run.

  `review` spawns a worker specialized for review tasks, optionally overriding
  the repo and model.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, repo: :string, model: :string]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["list" | _] ->
          list(mode)

        ["ls" | _] ->
          list(mode)

        ["show", task_id | _] ->
          show(task_id, mode)

        ["show" | _] ->
          Output.die("worker show requires: <task-id>")

        ["runs", task_id | _] ->
          runs(task_id, mode)

        ["runs" | _] ->
          Output.die("worker runs requires: <task-id>")

        ["log", task_id | _] ->
          log(task_id, mode)

        ["log" | _] ->
          Output.die("worker log requires: <task-id>")

        ["stop", task_id | _] ->
          stop(task_id, mode)

        ["stop" | _] ->
          Output.die("worker stop requires: <task-id>")

        ["review", task_id | opts] ->
          review(task_id, opts, mode)

        ["review" | _] ->
          Output.die("worker review requires: <task-id>")

        [] ->
          Output.die(
            "worker requires a subcommand: `list`, `show`, `runs`, `log`, `stop`, or `review`"
          )

        [unknown | _] ->
          Output.die("unknown worker subcommand: #{unknown}")
      end
    end
  end

  defp list(mode) do
    case Client.get("/api/workers") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(task_id, mode) do
    case Client.get("/api/workers/#{task_id}") do
      {:ok, snap} -> emit_show(snap, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp runs(task_id, mode) do
    case Client.get("/api/workers/history?task_id=#{URI.encode_www_form(task_id)}") do
      {:ok, %{"data" => list}} -> emit_runs(task_id, list, mode)
      {:ok, _} -> emit_runs(task_id, [], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp log(task_id, mode) do
    case Client.get("/api/workers/#{task_id}/log") do
      {:ok, %{"data" => data}} -> emit_log(data, mode)
      {:ok, payload} -> emit_log(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp stop(task_id, mode) do
    case Client.post("/api/workers/#{task_id}/stop", %{}) do
      {:ok, payload} -> emit_stop(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp review(task_id, opts, mode) do
    {flags, _rest, _invalid} = OptionParser.parse(opts, switches: @switches)

    body =
      %{"task_id" => task_id}
      |> maybe_put("repo", flags[:repo])
      |> maybe_put("model", flags[:model])

    case Client.post("/api/workers/review", body) do
      {:ok, payload} -> emit_review(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- render ---------------------------------------------------------

  defp emit_show(snap, :json), do: IO.puts(Jason.encode!(snap))

  defp emit_show(snap, :text) do
    if snap["source"] == "history" do
      IO.puts("(no live worker — showing most recent historical run)")
    end

    IO.puts("Issue:       #{snap["task_id"]}")
    if snap["worker_type"], do: IO.puts("Type:       #{snap["worker_type"]}")
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

  defp emit_runs(_task_id, list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_runs(_task_id, [], :text) do
    IO.puts("(no historical runs recorded for this task)")
  end

  defp emit_runs(task_id, list, :text) do
    IO.puts("Historical runs for #{task_id} (#{length(list)}, newest first):")

    Enum.each(list, fn r ->
      model_part = if r["model"], do: "  model=#{r["model"]}", else: ""
      completed = r["completed_at"] || "—"

      IO.puts(
        "  #{r["id"]}  type=#{r["worker_type"]}  status=#{r["status"]}  " <>
          "started=#{r["started_at"]}  completed=#{completed}#{model_part}"
      )

      if r["failure_reason"], do: IO.puts("      failure: #{r["failure_reason"]}")
    end)
  end

  defp emit_log(data, :json), do: IO.puts(Jason.encode!(data))

  defp emit_log(data, :text) do
    IO.puts("Issue:       #{data["task_id"]}")
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
    IO.puts("Stopped worker for issue #{payload["task_id"]}.")
  end

  defp emit_review(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_review(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}

    IO.puts("Review worker spawned:")
    IO.puts("  Issue:  #{task["id"]}")
    IO.puts("  Worker: #{worker["pid"]}")

    case payload["worktree_path"] do
      nil -> :ok
      path -> IO.puts("  Worktree: #{path}")
    end
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
        "  #{p["task_id"]}  status=#{p["status"]}  #{step}  repo=#{p["repo"]}  started=#{p["started_at"]}#{model_part}#{cost_part}"
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
