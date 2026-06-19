defmodule ArbiterWeb.Api.UsageController do
  @moduledoc """
  REST endpoints for the structured usage ledger (`Arbiter.Usage.Event`).

  Routes:

    * `GET /api/usage`          — aggregated rollup. Required query: `by` (one of
                                  `day | bead | campaign | workspace | repo |
                                  model | step | provider`). Optional:
                                  `workspace_id`, `since` (ISO8601), `limit`.
    * `GET /api/usage/events`   — raw event list (newest first). Optional
                                  filters: `workspace_id`, `bead_id`, `since`,
                                  `step`, `limit` (default 50).

  Both back the `arb usage` CLI; the rollup is the primary surface (per-day
  spend, top beads, rework cost). `events` is for debugging / drill-down.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_event_limit 50

  def summarize(conn, params) do
    with {:ok, by} <- parse_by(params["by"]),
         {:ok, since} <- parse_since(params["since"]),
         {:ok, limit} <- parse_optional_limit(params["limit"]) do
      opts =
        [by: by]
        |> add_opt(:since, since)
        |> add_opt(:workspace_id, params["workspace_id"])
        |> add_opt(:limit, limit)

      case Usage.summarize(opts) do
        {:ok, rollups} ->
          json(conn, %{by: Atom.to_string(by), data: Enum.map(rollups, &render_rollup/1)})

        {:error, reason} ->
          {:error, {:invalid_request, "could not summarize usage: #{inspect(reason)}"}}
      end
    end
  end

  def events(conn, params) do
    with {:ok, since} <- parse_since(params["since"]),
         {:ok, step} <- parse_step(params["step"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      events =
        Event
        |> filter_eq(:workspace_id, params["workspace_id"])
        |> filter_eq(:bead_id, params["bead_id"])
        |> filter_eq(:step, step)
        |> filter_since(since)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      json(conn, %{data: Enum.map(events, &render_event/1)})
    end
  end

  # ---- rendering ---------------------------------------------------------

  defp render_rollup(%{group: g} = r) do
    %{
      group: render_group(g),
      rows: r.rows,
      total_cost_usd: round_money(r.total_cost_usd),
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      cache_creation_tokens: r.cache_creation_tokens,
      cache_read_tokens: r.cache_read_tokens,
      duration_ms: r.duration_ms
    }
  end

  defp render_group(g) when is_binary(g), do: g
  defp render_group(g) when is_atom(g), do: Atom.to_string(g)
  defp render_group(g), do: inspect(g)

  defp render_event(%Event{} = ev) do
    %{
      id: ev.id,
      bead_id: ev.bead_id,
      workspace_id: ev.workspace_id,
      repo: ev.repo,
      step: Atom.to_string(ev.step),
      model: ev.model,
      provider: ev.provider,
      tokens_in: ev.tokens_in,
      tokens_out: ev.tokens_out,
      cache_creation_tokens: ev.cache_creation_tokens,
      cache_read_tokens: ev.cache_read_tokens,
      cost_usd: ev.cost_usd,
      duration_ms: ev.duration_ms,
      exit_status: ev.exit_status,
      occurred_at: iso(ev.occurred_at),
      session_id: ev.session_id,
      worker_run_id: ev.worker_run_id
    }
  end

  defp round_money(nil), do: nil
  defp round_money(n) when is_number(n), do: Float.round(n / 1, 6)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ---- query helpers -----------------------------------------------------

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, _key, ""), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_eq(query, _field, value) when value in [nil, ""], do: query
  defp filter_eq(query, :workspace_id, v), do: Ash.Query.filter(query, workspace_id == ^v)

  defp filter_eq(query, :bead_id, v) do
    prefix = v <> "#%"
    Ash.Query.filter(query, bead_id == ^v or like(bead_id, ^prefix))
  end

  defp filter_eq(query, :step, v), do: Ash.Query.filter(query, step == ^v)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at >= ^dt)

  # ---- param coercion ----------------------------------------------------

  defp parse_by(nil), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}
  defp parse_by(""), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}

  defp parse_by(raw) when is_binary(raw) do
    try do
      atom = String.to_existing_atom(raw)

      if atom in Usage.valid_groupings() do
        {:ok, atom}
      else
        {:error,
         {:invalid_request, "invalid by: #{inspect(raw)} (expected one of #{by_options()})"}}
      end
    rescue
      ArgumentError ->
        {:error,
         {:invalid_request, "invalid by: #{inspect(raw)} (expected one of #{by_options()})"}}
    end
  end

  defp by_options do
    Usage.valid_groupings() |> Enum.map_join(", ", &Atom.to_string/1)
  end

  defp parse_since(nil), do: {:ok, nil}
  defp parse_since(""), do: {:ok, nil}

  defp parse_since(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "since must be ISO8601 (e.g. 2026-06-01T00:00:00Z)"}}
    end
  end

  defp parse_step(nil), do: {:ok, nil}
  defp parse_step(""), do: {:ok, nil}

  defp parse_step(raw) when is_binary(raw) do
    try do
      atom = String.to_existing_atom(raw)

      if atom in Event.steps() do
        {:ok, atom}
      else
        {:error, {:invalid_request, "invalid step: #{inspect(raw)}"}}
      end
    rescue
      ArgumentError -> {:error, {:invalid_request, "invalid step: #{inspect(raw)}"}}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_event_limit}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_limit(_), do: {:error, {:invalid_request, "limit must be a positive integer"}}

  defp parse_optional_limit(nil), do: {:ok, nil}
  defp parse_optional_limit(""), do: {:ok, nil}
  defp parse_optional_limit(raw), do: parse_limit(raw)
end
