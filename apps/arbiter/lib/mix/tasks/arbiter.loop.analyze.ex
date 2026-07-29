defmodule Mix.Tasks.Arbiter.Loop.Analyze do
  @shortdoc "Stage 1 loop-analysis pass — emit a report, write nothing else"
  @moduledoc """
  The operator-invoked, **manual** Stage 1 loop-analysis pass (bd-dyfaq3, epic
  #1011).

  Runs over a window of the loop's own telemetry (`worker_runs ⨝ usage_events
  ⨝ review_gate_rounds ⨝ issues`), segments failures operational-vs-agent-quality
  by allowlist, corroborates each `failure_reason` against the transcript, and
  emits a markdown report. It performs **zero writes** to skills, config, or
  issues — the operator reads the report and decides where each lesson lands.
  The **only** write is a single `usage_events` cost row for the pass itself, so
  the loop's own cost appears in the ledger it is optimising (skip with
  `--no-ledger`).

  ## Usage

      mix arbiter.loop.analyze                       # last 7 days → stdout
      mix arbiter.loop.analyze --since 14d            # last 14 days
      mix arbiter.loop.analyze --out loop-report.md   # also write to a file
      mix arbiter.loop.analyze --no-ledger            # do not record the cost row
      mix arbiter.loop.analyze --limit 300            # cap runs scanned (newest first)

  `--since` accepts `Nd` (days) or an ISO-8601 date/datetime. `--until` defaults
  to now.

  This is the executable half of the pass. The interpretive discipline — how to
  cluster reviewer findings, the ≥3-incident / ≥2-task evidence bar, and where a
  lesson lands (a skill, the repo's `CLAUDE.md`, or a per-task override) — is in
  `docs/loop-review.md`. Read the report; do not let the pass self-modify.
  """

  use Mix.Task

  alias Arbiter.Loop.Analysis

  @switches [
    since: :string,
    until: :string,
    out: :string,
    label: :string,
    limit: :integer,
    ledger: :boolean,
    workspace: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    # A read-only analysis pass has no business booting the worker fleet, web
    # endpoint, or patrol supervisors — and doing so on a live box would trip
    # the single-instance guard and could disrupt in-flight workers. Load the
    # runtime config (so the Repo resolves DATABASE_PATH) and start only the
    # database layer.
    Mix.Task.run("app.config")
    # Keep the operator's console to the report — disable Ecto's per-query
    # logging that would otherwise bury it.
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    until = parse_dt(opts[:until]) || DateTime.utc_now()
    since = parse_since(opts[:since], until)

    analyze_opts =
      [since: since, until: until]
      |> put_opt(:label, opts[:label])
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:workspace_id, opts[:workspace])
      |> Keyword.put(:record_cost?, opts[:ledger] != false)

    case Analysis.analyze(analyze_opts) do
      {:ok, %{markdown: markdown, usage_event_id: uid}} ->
        maybe_write(opts[:out], markdown)
        unless opts[:out], do: Mix.shell().info(markdown)

        Mix.shell().info("\n---\nCost row: #{ledger_note(uid, opts[:ledger])}")

      {:error, reason} ->
        Mix.raise("loop-analysis failed: #{inspect(reason)}")
    end
  end

  defp maybe_write(nil, _markdown), do: :ok

  defp maybe_write(path, markdown) do
    File.write!(path, markdown)
    Mix.shell().info("Report written to #{path}")
  end

  defp ledger_note(_uid, false), do: "skipped (--no-ledger)"
  defp ledger_note(nil, _), do: "not recorded (insert failed — see logs)"
  defp ledger_note(uid, _), do: "recorded as usage_events #{uid}"

  # `Nd` (days back from `until`) or an ISO date/datetime; default 7 days.
  defp parse_since(nil, until), do: DateTime.add(until, -7 * 24 * 3600, :second)

  defp parse_since(str, until) do
    case Regex.run(~r/^(\d+)d$/, str) do
      [_, n] -> DateTime.add(until, -String.to_integer(n) * 24 * 3600, :second)
      _ -> parse_dt(str) || Mix.raise("bad --since: #{str} (use `Nd` or an ISO date)")
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp put_opt(kw, _key, nil), do: kw
  defp put_opt(kw, key, value), do: Keyword.put(kw, key, value)
end
