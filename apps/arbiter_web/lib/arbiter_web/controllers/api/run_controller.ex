defmodule ArbiterWeb.Api.RunController do
  @moduledoc """
  REST endpoints for `Arbiter.Polecats.Run` — the durable history of worker
  runs (a polecat's lifecycle after the GenServer is gone).

  Routes:

    * `GET /api/polecats/history`      — :index (filters: workspace_id, status,
                                          limit [default 20], before [ISO8601
                                          started_at cursor])
    * `GET /api/polecats/history/:id`  — :show (single run with full output)

  Newest first.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Polecats.Run
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_limit 20

  def index(conn, params) do
    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, status} <- parse_status(params["status"]),
         {:ok, before} <- parse_before(params["before"]) do
      runs =
        Run
        |> filter_eq(:workspace_id, params["workspace_id"])
        |> filter_eq(:status, status)
        |> filter_before(before)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      render(conn, :index, runs: runs)
    end
  end

  def show(conn, %{"id" => id}) when is_binary(id) and id != "" do
    case Ash.get(Run, id) do
      {:ok, run} -> render(conn, :show, run: run)
      {:error, _} -> {:error, :not_found}
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "id is required", %{}}}

  # ---- query helpers ----

  defp filter_eq(query, _field, value) when value in [nil, ""], do: query

  defp filter_eq(query, :workspace_id, value),
    do: Ash.Query.filter(query, workspace_id == ^value)

  defp filter_eq(query, :status, value), do: Ash.Query.filter(query, status == ^value)

  defp filter_before(query, nil), do: query
  defp filter_before(query, %DateTime{} = dt), do: Ash.Query.filter(query, started_at < ^dt)

  # ---- param coercion ----

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(_), do: {:error, {:invalid_request, "limit must be a positive integer"}}

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(raw) when is_binary(raw) do
    try do
      atom = String.to_existing_atom(raw)

      if atom in Run.statuses() do
        {:ok, atom}
      else
        {:error, {:invalid_request, "invalid status: #{inspect(raw)}"}}
      end
    rescue
      ArgumentError -> {:error, {:invalid_request, "invalid status: #{inspect(raw)}"}}
    end
  end

  defp parse_before(nil), do: {:ok, nil}
  defp parse_before(""), do: {:ok, nil}

  defp parse_before(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "before must be ISO8601 (e.g. 2026-05-27T20:00:00Z)"}}
    end
  end
end
