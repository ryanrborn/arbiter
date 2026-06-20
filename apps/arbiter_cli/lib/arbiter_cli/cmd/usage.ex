defmodule ArbiterCli.Cmd.Usage do
  @moduledoc """
  `arb usage` — surface the structured token / cost ledger.

  Every Claude session (work worker or ReviewGate reviewer) writes a usage row
  with tokens (in/out/cache), cost in USD, duration, model, and provider. This
  command rolls those rows up so you can answer "spend per campaign / per day
  / per workspace" — and, by counting `:work` rows per task, see what got
  re-slung (rework spend).

  Usage:

      arb usage [--by day|task|campaign|workspace|repo|model|step|provider]
                [--since YYYY-MM-DD | <iso8601>]
                [--workspace <id>]
                [--limit N]
                [--json]
      arb usage events [--task <task-id>] [--workspace <id>] [--step work|review]
                       [--since ...] [--limit N] [--json]

  Defaults to `--by day`. `--since 7d` and `--since 24h` are accepted as
  shortcuts. `events` lists raw rows newest-first (default limit 50) and is
  the drill-down path when a rollup catches your eye.
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
        ["events" | tail] -> events(tail, mode)
        _ -> summarize(rest, mode)
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
          since: :string,
          limit: :integer
        ]
      )

    params =
      []
      |> maybe_put(:task_id, Keyword.get(opts, :task))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))
      |> maybe_put(:step, Keyword.get(opts, :step))
      |> maybe_put(:since, normalize_since(Keyword.get(opts, :since)))
      |> maybe_put(:limit, Keyword.get(opts, :limit) || @default_event_limit)

    case Client.get("/api/usage/events", params) do
      {:ok, %{"data" => rows}} -> emit_events(rows, mode)
      {:error, err} -> Output.die(err)
    end
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

    IO.puts(
      "  -- total: $#{format_cost(totals.cost)} · #{format_int(totals.tokens_in)} in / #{format_int(totals.tokens_out)} out · #{length(rollups)} groups · #{totals.rows} sessions"
    )
  end

  defp emit_events(rows, :json), do: IO.puts(Jason.encode!(%{"data" => rows}))

  defp emit_events([], :text), do: IO.puts("(no usage events)")

  defp emit_events(rows, :text) do
    IO.puts("Usage events (#{length(rows)}):")

    Enum.each(rows, fn ev ->
      IO.puts(
        "  #{ev["occurred_at"]}  task=#{ev["task_id"]}  step=#{ev["step"]}  model=#{ev["model"]}  cost=$#{format_cost(ev["cost_usd"])}  in=#{format_int(ev["tokens_in"])}  out=#{format_int(ev["tokens_out"])}  dur=#{format_seconds(ev["duration_ms"])}"
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

  defp format_cost(nil), do: "0.0000"

  defp format_cost(n) when is_number(n) do
    :erlang.float_to_binary(n / 1, decimals: 4)
  end

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
    Enum.reduce(rollups, %{cost: 0.0, tokens_in: 0, tokens_out: 0, rows: 0}, fn r, acc ->
      %{
        cost: acc.cost + (r["total_cost_usd"] || 0.0),
        tokens_in: acc.tokens_in + (r["tokens_in"] || 0),
        tokens_out: acc.tokens_out + (r["tokens_out"] || 0),
        rows: acc.rows + (r["rows"] || 0)
      }
    end)
  end
end
