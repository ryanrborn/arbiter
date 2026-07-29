defmodule ArbiterWeb.Api.LoopController do
  @moduledoc """
  REST surface for the Stage 1 loop-analysis pass (bd-dyfaq3).

    * `GET /api/loop/analyze` — run the operator-invoked loop-analysis pass over
      a window and return its markdown report. Optional query params: `since`
      (`7d` / `24h` / `30m` shortcuts or ISO8601; default: last 7 days), `until`
      (ISO8601; default now), `limit` (cap on runs scanned, newest first),
      `workspace_id`, `label`.

  The pass is **report-only**: it writes nothing but its own `usage_events`
  cost row (`Arbiter.Loop.Analysis`). Backs the `arb loop analyze` CLI.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Loop.Analysis

  action_fallback(ArbiterWeb.Api.FallbackController)

  def analyze(conn, params) do
    with {:ok, since} <- parse_window(params["since"]),
         {:ok, until} <- parse_iso(params["until"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      opts =
        []
        |> put(:since, since)
        |> put(:until, until)
        |> put(:limit, limit)
        |> put(:workspace_id, blank_to_nil(params["workspace_id"]))
        |> put(:label, blank_to_nil(params["label"]))

      case Analysis.analyze(opts) do
        {:ok, %{markdown: markdown, report: report, usage_event_id: uid}} ->
          json(conn, %{
            markdown: markdown,
            usage_event_id: uid,
            summary: summary(report)
          })

        {:error, reason} ->
          {:error, {:invalid_request, "loop analysis failed: #{inspect(reason)}"}}
      end
    end
  end

  # A compact structured summary alongside the markdown, for programmatic callers.
  defp summary(report) do
    %{
      window: report.window[:label],
      totals: report.totals,
      misclassification_rate: report.misclassification[:rate],
      finding_categories: length(report.finding_categories),
      difficulty_misestimates: length(report.difficulty_misestimates),
      fleet_wide_suggestions: Enum.count(report.suggestions, &(&1.verdict == :fleet_wide))
    }
  end

  # ---- param parsing ------------------------------------------------------

  # Accepts relative shortcuts (7d / 24h / 30m) or absolute ISO8601.
  defp parse_window(nil), do: {:ok, nil}
  defp parse_window(""), do: {:ok, nil}

  defp parse_window(raw) when is_binary(raw) do
    case Regex.run(~r/^(\d+)([dhm])$/, raw) do
      [_, n, unit] ->
        seconds = String.to_integer(n) * unit_seconds(unit)
        {:ok, DateTime.add(DateTime.utc_now(), -seconds, :second)}

      nil ->
        parse_iso(raw)
    end
  end

  defp parse_iso(nil), do: {:ok, nil}
  defp parse_iso(""), do: {:ok, nil}

  defp parse_iso(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "expected ISO8601 or a 7d/24h/30m shortcut, got #{inspect(raw)}"}}
    end
  end

  defp parse_limit(nil), do: {:ok, nil}
  defp parse_limit(""), do: {:ok, nil}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp unit_seconds("d"), do: 24 * 3600
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("m"), do: 60

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
