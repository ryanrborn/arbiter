defmodule ArbiterCli.Cmd.Usage do
  @moduledoc """
  `arb usage` — surface the structured token / cost ledger.

  Every Claude session (work worker or ReviewGate reviewer) writes a usage row
  with tokens (in/out/cache), cost in USD, duration, model, and provider. This
  command rolls those rows up so you can answer "spend per epic / per day
  / per workspace" — and, by counting `:work` rows per task, see what got
  re-slung (rework spend).

  Usage:

      arb usage [--by day|task|epic|workspace|repo|model|step|provider|source|session]
                [--since YYYY-MM-DD | <iso8601>]
                [--workspace <id>]
                [--limit N]
                [--json]
      arb usage events [--task <task-id>] [--workspace <id>] [--step work|review|impl]
                       [--source task|probe|preflight|coordinator_session|terminal_session|maintenance]
                       [--since ...] [--limit N] [--json]
      arb usage --session <id> [--since ...] [--limit N] [--json]
      arb usage --calibration [--workspace <id>] [--window-days N] [--json]

  `--by campaign` is still accepted as a deprecated alias for `--by epic`.

  Defaults to `--by day`. `--since 7d` and `--since 24h` are accepted as
  shortcuts. `events` lists raw rows newest-first (default limit 50) and is
  the drill-down path when a rollup catches your eye.

  ## Not all spend belongs to a task (bd-adyhvn)

  Quota refresh probes, the per-dispatch auth pre-flight, and the coordinator's
  own Claude Code sessions spend real plan quota with no task attached. They
  carry `source` instead, and `--by task` deliberately **excludes** them rather
  than inventing a phantom task id. `--by day`, `--by workspace` and `--by
  source` all count them, so:

      arb usage --by source --since 7d

  is the one rollup that shows the whole bill.

  `coordinator_session` rows arrive from `Arbiter.Sessions.UsageIngest`
  (bd-be804c), which meters the coordinator's session JSONLs on a timer. The
  coordinator is roughly a quarter of total consumption, so before that landed
  `--by source` was the "whole bill" only in principle. An install that has not
  set `ARBITER_COORDINATOR_SESSION_DIRS` still sees no such rows.

  Those rows are dated from the **session transcript's own timestamps**, one row
  per session per UTC day, so `--by day` and `--since` place the spend when it
  happened. The first sweep after enabling the ingest therefore backfills the
  whole history at its real dates — expect `--since 30d` to jump, and `--since
  1d` not to.

  ## `--by session` / `--session <id>` (§7.6)

  `--by session` groups session-sourced rows only (`session_id` present) into
  one row per session — cost, tokens, duration — mirroring how `--by task`
  above excludes rows that carry no task. `--session <id>` is the drill-down:
  the raw event rows for one session, newest first, the same shape `events`
  prints.

  ## `--calibration`: which D-ratings the money disagrees with (bd-3j4ch4)

  For every closed task in a 60-day window, compare what it actually cost
  against its own difficulty tier's p25–p75. A cost above its tier's p75 that
  lands inside the *next* tier's range reads as **possibly under-rated**;
  below its p25 and inside the *previous* tier's, **possibly over-rated**.
  Only tiers with at least ten closed tasks are used in either direction.

  This is a hint about ratings, not a verdict on a task: the spread inside a
  tier is wide by design, so a single flagged task means little and the
  per-tier *rate* is the number to read. Tasks re-dispatched after a failure
  (more than one work session) are listed but held out of those rates — a
  re-slung task costs double for reasons that say nothing about how hard it
  was, and counting it would read as "D-ratings run low".
  """

  alias ArbiterCli.{Client, Output}

  @default_by "day"
  @default_event_limit 50

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["events" | tail] ->
          events(tail, mode)

        _ ->
          cond do
            calibration?(rest) ->
              calibration(rest, mode)

            "--session" in rest and is_nil(session_flag(rest)) ->
              Output.die("--session requires an id")

            session_id = session_flag(rest) ->
              session_detail(session_id, rest, mode)

            true ->
              summarize(rest, mode)
          end
      end
    end
  end

  # ---- summarize ---------------------------------------------------------

  defp summarize(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [
          by: :string,
          since: :string,
          workspace: :string,
          limit: :integer
        ],
        aliases: [b: :by, s: :since, w: :workspace, l: :limit]
      )

    by = Keyword.get(opts, :by, @default_by)

    params =
      [by: by]
      |> maybe_put(:since, normalize_since(Keyword.get(opts, :since)))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case Client.get("/api/usage", params) do
      {:ok, %{"data" => rollups, "by" => ^by}} -> emit_summary(rollups, by, mode)
      {:ok, %{"data" => rollups}} -> emit_summary(rollups, by, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- events ------------------------------------------------------------

  defp events(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [
          task: :string,
          workspace: :string,
          step: :string,
          source: :string,
          session: :string,
          since: :string,
          limit: :integer
        ]
      )

    params =
      []
      |> maybe_put(:task_id, Keyword.get(opts, :task))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:step, Keyword.get(opts, :step))
      |> maybe_put(:source, Keyword.get(opts, :source))
      |> maybe_put(:session_id, Keyword.get(opts, :session))
      |> maybe_put(:since, normalize_since(Keyword.get(opts, :since)))
      |> maybe_put(:limit, Keyword.get(opts, :limit) || @default_event_limit)

    case Client.get("/api/usage/events", params) do
      {:ok, %{"data" => rows}} -> emit_events(rows, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- session detail (§7.6) ----------------------------------------------

  # `--session <id>` is a top-level flag (not nested under `events`), so it is
  # detected the same way `--calibration` is: parsed out of the raw argv
  # before deciding which subcommand to run.
  defp session_flag(argv) do
    {opts, _rest, _bad} = OptionParser.parse(argv, switches: [session: :string])
    Keyword.get(opts, :session)
  end

  defp session_detail(session_id, argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [session: :string, workspace: :string, since: :string, limit: :integer]
      )

    params =
      []
      |> maybe_put(:session_id, session_id)
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:since, normalize_since(Keyword.get(opts, :since)))
      |> maybe_put(:limit, Keyword.get(opts, :limit) || @default_event_limit)

    case Client.get("/api/usage/events", params) do
      {:ok, %{"data" => rows}} -> emit_events(rows, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- calibration -------------------------------------------------------

  defp calibration?(argv), do: "--calibration" in argv

  defp calibration(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [calibration: :boolean, workspace: :string, window_days: :integer],
        aliases: [w: :workspace]
      )

    params =
      []
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:window_days, Keyword.get(opts, :window_days))

    case Client.get("/api/usage/calibration", params) do
      {:ok, report} -> emit_calibration(report, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_calibration(report, :json), do: IO.puts(Jason.encode!(report))

  defp emit_calibration(report, :text) do
    tiers = report["tiers"] || []
    flagged = report["flagged"] || []

    IO.puts("Cost calibration — #{report["window_days"]}-day window, worker spend only")
    IO.puts("")

    if tiers == [] do
      IO.puts("  (no rated closed tasks in the window)")
    else
      IO.puts("  " <> calib_columns(["TIER", "N", "P25-P75", "UNDER-RATED", "OVER-RATED"]))

      Enum.each(tiers, &IO.puts("  " <> tier_row(&1)))
      IO.puts("")
      emit_flagged(flagged, "under_rated", "Possibly under-rated (cost fits the tier above):")
      emit_flagged(flagged, "over_rated", "Possibly over-rated (cost fits the tier below):")
      emit_footnote(report)
    end
  end

  defp tier_row(tier) do
    calib_columns([
      "D#{tier["difficulty"]}",
      to_string(tier["n"]),
      "#{dollars(tier["p25"])}-#{dollars(tier["p75"])}",
      "#{tier["under_rated"]} (#{percent(tier["under_rate"])})",
      "#{tier["over_rated"]} (#{percent(tier["over_rate"])})"
    ])
  end

  defp emit_flagged(flagged, direction, heading) do
    rows = Enum.filter(flagged, &(&1["direction"] == direction))

    IO.puts(heading)

    case rows do
      [] ->
        IO.puts("  (none)")

      rows ->
        Enum.each(rows, fn f ->
          # `*` marks a re-dispatched task, held out of the rates above, so the
          # list stays readable without cross-referencing the footnote.
          mark = if f["re_dispatched"], do: "*", else: " "

          IO.puts(
            "  #{mark}#{String.pad_trailing(to_string(f["task_id"]), 12)} " <>
              "D#{f["difficulty"]} -> D#{f["suggested_difficulty"]}  " <>
              "#{String.pad_leading(dollars(f["actual_cost_usd"]), 9)}  " <>
              "#{f["issue_type"]}  #{f["title"]}"
          )
        end)
    end

    IO.puts("")
  end

  defp emit_footnote(%{"re_dispatched_flagged" => n}) when is_integer(n) and n > 0 do
    IO.puts(
      "* #{n} flagged #{plural_task(n)} re-dispatched (more than one work session) and " <>
        "held out of the\n  per-tier rates above: re-slinging inflates cost without saying " <>
        "the rating was wrong."
    )
  end

  defp emit_footnote(_report), do: :ok

  defp plural_task(1), do: "task was"
  defp plural_task(_), do: "tasks were"

  defp dollars(nil), do: "-"
  defp dollars(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  defp percent(nil), do: "0.0%"
  defp percent(r) when is_number(r), do: :erlang.float_to_binary(r * 100, decimals: 1) <> "%"

  defp calib_columns(cells) do
    widths = [5, 5, 18, 15, 15]

    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(to_string(c), w) end)
  end

  # ---- render ------------------------------------------------------------

  defp emit_summary(rollups, by, :json),
    do: IO.puts(Jason.encode!(%{"by" => by, "data" => rollups}))

  defp emit_summary([], by, :text) do
    IO.puts("(no usage rows for --by #{by})")
  end

  defp emit_summary(rollups, by, :text) do
    IO.puts("Usage rollup by #{by} (#{length(rollups)} groups):")

    header =
      pad_columns(["GROUP", "ROWS", "COST_USD", "IN", "OUT", "CACHE_R", "CACHE_W", "SECONDS"])

    IO.puts("  " <> header)

    Enum.each(rollups, fn r ->
      row =
        pad_columns([
          to_string(r["group"]),
          to_string(r["rows"]),
          format_cost(r["total_cost_usd"]),
          format_int(r["tokens_in"]),
          format_int(r["tokens_out"]),
          format_int(r["cache_read_tokens"]),
          format_int(r["cache_creation_tokens"]),
          format_seconds(r["duration_ms"])
        ])

      IO.puts("  " <> row)
    end)

    totals = totals(rollups)
    total_cost_str = if totals.cost_known, do: "$#{format_cost(totals.cost)}", else: "n/a"

    IO.puts(
      "  -- total: #{total_cost_str} · #{format_int(totals.tokens_in)} in / #{format_int(totals.tokens_out)} out · #{length(rollups)} groups · #{totals.rows} sessions"
    )
  end

  defp emit_events(rows, :json), do: IO.puts(Jason.encode!(%{"data" => rows}))

  defp emit_events([], :text), do: IO.puts("(no usage events)")

  defp emit_events(rows, :text) do
    IO.puts("Usage events (#{length(rows)}):")

    Enum.each(rows, fn ev ->
      IO.puts(
        "  #{ev["occurred_at"]}  source=#{ev["source"] || "task"}  task=#{ev["task_id"] || "-"}  session=#{ev["session_id"] || "-"}  step=#{ev["step"]}  model=#{ev["model"]}  cost=#{cost_label(ev["cost_usd"])}  in=#{format_int(ev["tokens_in"])}  out=#{format_int(ev["tokens_out"])}  dur=#{format_seconds(ev["duration_ms"])}"
      )
    end)
  end

  # ---- helpers -----------------------------------------------------------

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Accept ISO8601 verbatim, or `Nd` / `Nh` shorthands ("7d", "24h") which we
  # translate into an absolute timestamp. Keeps the common case ("last week")
  # ergonomic without giving up arbitrary precision.
  defp normalize_since(nil), do: nil
  defp normalize_since(""), do: nil

  defp normalize_since(<<n::binary-size(1), "d">>), do: shift_back_days(parse_int(n))
  defp normalize_since(<<n::binary-size(2), "d">>), do: shift_back_days(parse_int(n))
  defp normalize_since(<<n::binary-size(3), "d">>), do: shift_back_days(parse_int(n))

  defp normalize_since(<<n::binary-size(1), "h">>), do: shift_back_hours(parse_int(n))
  defp normalize_since(<<n::binary-size(2), "h">>), do: shift_back_hours(parse_int(n))
  defp normalize_since(<<n::binary-size(3), "h">>), do: shift_back_hours(parse_int(n))

  defp normalize_since(raw), do: raw

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp shift_back_days(n) when is_integer(n) and n > 0 do
    DateTime.utc_now()
    |> DateTime.add(-n * 86_400, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp shift_back_days(_), do: nil

  defp shift_back_hours(n) when is_integer(n) and n > 0 do
    DateTime.utc_now()
    |> DateTime.add(-n * 3_600, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp shift_back_hours(_), do: nil

  # nil means "no priced cost known" (e.g. agy/Antigravity, a subscription
  # with no per-call dollar figure) — never render that as "$0.0000", which
  # reads as "this session was free" rather than "cost is unknowable here".
  defp format_cost(nil), do: "n/a"

  defp format_cost(n) when is_number(n) do
    :erlang.float_to_binary(n / 1, decimals: 4)
  end

  defp cost_label(nil), do: "n/a"
  defp cost_label(n) when is_number(n), do: "$" <> format_cost(n)

  defp format_int(nil), do: "0"
  defp format_int(n) when is_integer(n), do: Integer.to_string(n)
  defp format_int(n) when is_float(n), do: Integer.to_string(trunc(n))

  defp format_seconds(nil), do: "0.0s"

  defp format_seconds(ms) when is_number(ms) do
    :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  end

  # Print rows with simple column widths so a one-liner stays readable. Stable
  # set of columns; no clever ragged-tabular alignment.
  defp pad_columns(cells) do
    widths = [26, 6, 10, 10, 10, 10, 10, 10]

    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(to_string(c), w) end)
  end

  defp totals(rollups) do
    Enum.reduce(
      rollups,
      %{cost: 0.0, cost_known: false, tokens_in: 0, tokens_out: 0, rows: 0},
      fn r, acc ->
        %{
          cost: acc.cost + (r["total_cost_usd"] || 0.0),
          # At least one group had a priced cost — an all-agy rollup (every
          # group's total_cost_usd nil) must render "n/a", not "$0.0000",
          # which reads as "this window was free" (see format_cost/1).
          cost_known: acc.cost_known or is_number(r["total_cost_usd"]),
          tokens_in: acc.tokens_in + (r["tokens_in"] || 0),
          tokens_out: acc.tokens_out + (r["tokens_out"] || 0),
          rows: acc.rows + (r["rows"] || 0)
        }
      end
    )
  end
end
