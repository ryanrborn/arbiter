defmodule ArbiterCli.Cmd.Loop do
  @moduledoc """
  `arb loop` — the operator-invoked loop-engineering surface.

  ## `arb loop analyze`

  Run the Stage 1 loop-analysis pass (bd-dyfaq3) over a window and print its
  markdown report. The pass reads `worker_runs ⨝ usage_events ⨝
  review_gate_rounds ⨝ issues`, segments failures operational-vs-agent-quality
  by allowlist (corroborating each `failure_reason` against the transcript),
  clusters reviewer findings, and flags difficulty misestimates — then emits a
  report and **writes nothing** but its own cost row. The operator reads it and
  decides where each lesson lands (a skill, the repo's `CLAUDE.md`, or a
  per-task override).

  Usage:

      arb loop analyze [--since 7d | <iso8601>] [--until <iso8601>]
                       [--limit N] [--workspace <id>] [--propose] [--json]

  `--since` accepts `7d` / `24h` / `30m` shortcuts or ISO8601 (default: last 7
  days). `--json` prints the raw envelope (markdown + structured summary)
  instead of just the report.

  Without `--propose` the pass is read-only, exactly as it has always been.
  `--propose` additionally persists the proposals the report implies into the
  reviewable queue below — nothing is applied, at any evidence level.

  ## The proposal queue (Stage 2, bd-9j2g3x)

      arb loop pending [--state proposed|hypothesis|applied|rejected|superseded]
                       [--kind <kind>] [--workspace <id>] [--limit N] [--json]
      arb loop diff <id>
      arb loop apply <id>
      arb loop apply all [--state proposed]
      arb loop reject <id> [--reason "..."]

  A finding below the evidence bar is kept as a `hypothesis` carrying its
  incident refs, so a later window reinforces it in place rather than starting
  its count from zero. Crossing the bar (default: 3 incidents across 2 distinct
  tasks, overridable per workspace under `loop.evidence_bar`) promotes it to
  `proposed` and escalates once. `arb loop pending` shows the live states
  (`hypothesis` + `proposed`) unless `--state` says otherwise.

  Each row is priced as well as counted: the `+120ctx` / `free` column is the
  *recurring* context the proposal would add to every future dispatch if
  applied. A per-task override and a difficulty change are free forever; a
  fleet-wide skill clause is not, and the price is in view before you approve it.

  `apply` calls the same public domain API a human would, so every application
  leaves a normal paper-trail version attributed to the proposal id. Rejection
  is soft: the row persists as `rejected` and keeps accumulating evidence, but
  never re-opens on its own.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["analyze" | tail] -> analyze(tail, mode)
        ["pending" | tail] -> pending(tail, mode)
        ["diff", id | _] -> diff(id)
        ["diff" | _] -> Output.die("usage: arb loop diff <id>")
        ["apply", "all" | tail] -> apply_all(tail, mode)
        ["apply", id | _] -> apply_one(id, mode)
        ["apply" | _] -> Output.die("usage: arb loop apply <id> | arb loop apply all")
        ["reject", id | tail] -> reject(id, tail, mode)
        ["reject" | _] -> Output.die("usage: arb loop reject <id> [--reason \"...\"]")
        [] -> analyze([], mode)
        [other | _] -> Output.die("unknown `arb loop` subcommand: #{other}")
      end
    end
  end

  defp analyze(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [
          since: :string,
          until: :string,
          limit: :integer,
          workspace: :string,
          propose: :boolean
        ],
        aliases: [s: :since, l: :limit, w: :workspace]
      )

    params =
      []
      |> maybe_put(:since, Keyword.get(opts, :since))
      |> maybe_put(:until, Keyword.get(opts, :until))
      |> maybe_put(:limit, Keyword.get(opts, :limit))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))

    # `--propose` is a different verb on a different route, not a flag on the
    # read-only GET — the analyze endpoint can never write.
    result =
      if Keyword.get(opts, :propose, false) do
        Client.post("/api/loop/propose", Map.new(params))
      else
        Client.get("/api/loop/analyze", params)
      end

    case result do
      {:ok, %{"markdown" => markdown} = envelope} -> emit(markdown, envelope, mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit(_markdown, envelope, :json), do: IO.puts(Jason.encode!(envelope))

  defp emit(markdown, envelope, :text) do
    IO.puts(markdown)

    case Map.get(envelope, "proposals") do
      rows when is_list(rows) and rows != [] ->
        IO.puts("\n## Queued proposals (#{length(rows)})\n")
        Enum.each(rows, &IO.puts(pending_line(&1)))
        IO.puts("\nReview with `arb loop pending`; apply with `arb loop apply <id>`.")

      _ ->
        :ok
    end
  end

  # ---- the proposal queue -------------------------------------------------

  defp pending(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [state: :string, kind: :string, workspace: :string, limit: :integer],
        aliases: [l: :limit, w: :workspace]
      )

    params =
      []
      |> maybe_put(:state, Keyword.get(opts, :state))
      |> maybe_put(:kind, Keyword.get(opts, :kind))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case Client.get("/api/loop/pending", params) do
      {:ok, %{"pending" => rows} = envelope} -> emit_pending(rows, envelope, mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_pending(_rows, envelope, :json), do: IO.puts(Jason.encode!(envelope))

  defp emit_pending([], envelope, :text) do
    bar = Map.get(envelope, "evidence_bar") || %{}

    IO.puts(
      "no queued loop proposals (evidence bar: #{Map.get(bar, "min_incidents")} incidents " <>
        "across #{Map.get(bar, "min_distinct_tasks")} distinct tasks)"
    )
  end

  defp emit_pending(rows, _envelope, :text) do
    Enum.each(rows, &IO.puts(pending_line(&1)))
  end

  defp pending_line(row) do
    [
      String.pad_trailing(to_string(row["id"]), 38),
      String.pad_trailing(to_string(row["state"]), 11),
      String.pad_trailing(to_string(row["kind"]), 20),
      String.pad_trailing("#{row["evidence_count"]}i/#{row["distinct_tasks"]}t", 9),
      String.pad_trailing(context_cost(row["context_cost_tokens"]), 9),
      to_string(row["gist"])
    ]
    |> Enum.join(" ")
  end

  # Amendment D: the recurring per-dispatch price of applying a proposal, shown
  # in the queue itself so a fleet-wide prompt addition can't be approved
  # without its standing cost in view. A per-task override is genuinely free
  # forever, and "free" says that more plainly than "0ctx".
  defp context_cost(tokens) when is_integer(tokens) and tokens > 0, do: "+#{tokens}ctx"
  defp context_cost(_), do: "free"

  defp context_cost_detail(tokens) when is_integer(tokens) and tokens > 0,
    do: "~#{tokens} token(s) added to every dispatch that carries this, for as long as it lives"

  defp context_cost_detail(_), do: "0 tokens (charged once, not to every dispatch)"

  defp diff(id) do
    case Client.get("/api/loop/pending/#{id}") do
      {:ok, %{"pending" => row}} -> print_detail(row)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp print_detail(row) do
    IO.puts("#{row["id"]}  #{row["state"]}  #{row["kind"]}  (scope: #{row["scope"]})")
    IO.puts(row["gist"])

    IO.puts(
      "\nevidence: #{row["evidence_count"]} incident(s) across " <>
        "#{row["distinct_tasks"]} distinct task(s)"
    )

    IO.puts("context cost: #{context_cost_detail(row["context_cost_tokens"])}")

    if row["target_metric"], do: IO.puts("target metric: #{row["target_metric"]}")
    if row["baseline"], do: IO.puts("baseline: #{row["baseline"]}")
    if row["inapplicable_reason"], do: IO.puts("\nnot applicable: #{row["inapplicable_reason"]}")

    case row["diff"] do
      diff when is_binary(diff) and diff != "" -> IO.puts("\n" <> diff)
      _ -> IO.puts("\n(no diff — this proposal carries a payload, not a patch)")
    end
  end

  defp apply_one(id, mode) do
    case Client.post("/api/loop/pending/#{id}/apply", %{}) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "applied", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  # `apply all` is a convenience over the same per-row endpoint — never a
  # server-side bulk write, so one bad row cannot take the batch with it.
  defp apply_all(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [state: :string, workspace: :string, limit: :integer],
        aliases: [l: :limit, w: :workspace]
      )

    params =
      [state: Keyword.get(opts, :state, "proposed")]
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case Client.get("/api/loop/pending", params) do
      {:ok, %{"pending" => []}} ->
        IO.puts("nothing to apply")

      {:ok, %{"pending" => rows}} ->
        Enum.each(rows, fn row -> apply_in_batch(row, mode) end)

      {:ok, other} ->
        Output.die("unexpected response: #{inspect(other)}")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp apply_in_batch(row, mode) do
    case Client.post("/api/loop/pending/#{row["id"]}/apply", %{}) do
      {:ok, %{"pending" => applied}} ->
        emit_decision(applied, "applied", mode)

      {:ok, other} ->
        IO.puts("#{row["id"]} skipped: unexpected response #{inspect(other)}")

      {:error, err} ->
        IO.puts("#{row["id"]} skipped: #{error_message(err)}")
    end
  end

  defp reject(id, argv, mode) do
    {opts, _rest, _bad} = OptionParser.parse(argv, switches: [reason: :string])
    body = maybe_put_map(%{}, "reason", Keyword.get(opts, :reason))

    case Client.post("/api/loop/pending/#{id}/reject", body) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "rejected", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_decision(row, _verb, :json), do: IO.puts(Jason.encode!(row))
  defp emit_decision(row, verb, :text), do: IO.puts("#{verb} #{row["id"]}: #{row["gist"]}")

  defp error_message(%Client.Error{message: message}) when is_binary(message), do: message
  defp error_message(err), do: inspect(err)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, ""), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)
end
