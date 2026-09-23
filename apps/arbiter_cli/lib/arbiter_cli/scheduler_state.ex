defmodule ArbiterCli.SchedulerState do
  @moduledoc """
  Reads and renders the scheduler drain state (`GET /api/scheduler/status`,
  bd-9fgg04 / #1903) for every CLI surface that shows it — `arb scheduler
  status|wait`, `arb prime`, `arb server doctor` — so none of them word
  "safe to restart" differently.

  The server decides the state (`Arbiter.Board.Drain`); this module only
  renders it. A body without a `state` key comes from a server that predates
  the drain state: it is reported as unknown, never as safe.
  """

  alias ArbiterCli.Client

  @doc "Fetch the drain state body."
  @spec fetch() :: {:ok, map()} | {:error, Client.Error.t()}
  def fetch do
    case Client.get("/api/scheduler/status") do
      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:ok, other} ->
        {:error, %Client.Error{kind: :decode, message: "unexpected body: #{inspect(other)}"}}

      {:error, _} = err ->
        err
    end
  end

  @doc ~s|`"running"`, `"draining"`, `"quiescent"` — or `"unknown"` from an older server.|
  @spec state(map()) :: String.t()
  def state(%{"state" => state}) when state in ["running", "draining", "quiescent"], do: state
  def state(_), do: "unknown"

  @doc "The in-flight entries (empty when absent)."
  @spec in_flight(map()) :: [map()]
  def in_flight(%{"in_flight" => list}) when is_list(list), do: list
  def in_flight(_), do: []

  @doc "One line: the state and what it means for a restart."
  @spec headline(map()) :: String.t()
  def headline(body) do
    case state(body) do
      "running" ->
        "running — the autopilot is promoting; not a safe restart point"

      "draining" ->
        n = length(in_flight(body))

        "paused, draining — #{n} in flight; NOT safe to restart " <>
          "(a pause stops new board dispatches, not work already under way)"

      "quiescent" ->
        "paused, quiescent — nothing in flight; safe to restart"

      "unknown" ->
        paused = if body["paused"], do: "paused", else: "running"
        "#{paused} — drain state unknown (the server predates it); check `arb worker list`"
    end
  end

  @doc "One display line per in-flight entry, oldest first as the server sent them."
  @spec entry_lines(map(), DateTime.t()) :: [String.t()]
  def entry_lines(body, now \\ DateTime.utc_now()) do
    Enum.map(in_flight(body), &entry_line(&1, now))
  end

  defp entry_line(entry, now) do
    [
      String.pad_trailing(to_string(entry["kind"] || "?"), 18),
      String.pad_trailing(entry["task_id"] || "-", 16),
      String.pad_trailing(entry["status"] || "", 12),
      age(entry["started_at"], now),
      suffix(entry)
    ]
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp suffix(entry) do
    case entry["detail"] || entry["registry_key"] do
      nil -> ""
      text -> "(#{text})"
    end
  end

  defp age(iso, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt |> then(&DateTime.diff(now, &1)) |> humanize() |> String.pad_trailing(6)
      _ -> String.pad_trailing("", 6)
    end
  end

  defp age(_, _), do: String.pad_trailing("", 6)

  defp humanize(s) when s < 60, do: "#{max(s, 0)}s"
  defp humanize(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize(s), do: "#{div(s, 3600)}h#{div(rem(s, 3600), 60)}m"
end
