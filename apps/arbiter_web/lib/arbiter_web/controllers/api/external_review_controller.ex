defmodule ArbiterWeb.Api.ExternalReviewController do
  @moduledoc """
  REST endpoint for the ExternalReview audit ledger (bd-31fh9e).

  Route:

    * `GET /api/external_reviews` — list recent records, newest first.
      Optional query params:
        * `workspace_id` — restrict to one workspace.
        * `status`       — filter by `running` | `completed` | `failed`.
        * `since`        — ISO8601 lower bound on `started_at`.
        * `limit`        — max rows (default 50, max 500).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Reviews.Record
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_limit 50
  @max_limit 500

  def index(conn, params) do
    with {:ok, since} <- parse_since(params["since"]),
         {:ok, status} <- parse_status(params["status"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      records =
        Record
        |> filter_workspace(params["workspace_id"])
        |> filter_status(status)
        |> filter_since(since)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      json(conn, %{data: Enum.map(records, &render_record/1)})
    end
  end

  # ---- rendering -----------------------------------------------------------

  defp render_record(%Record{} = r) do
    %{
      id: r.id,
      pr_ref: r.pr_ref,
      pr: r.pr,
      workspace_id: r.workspace_id,
      strategy: r.strategy,
      link: r.link,
      status: r.status,
      verdict: r.verdict,
      finding_count: r.finding_count,
      findings_summary: r.findings_summary,
      model: r.model,
      cost_usd: r.cost_usd,
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      dispatched_by: r.dispatched_by,
      engagement_id: r.engagement_id,
      started_at: iso(r.started_at),
      completed_at: iso(r.completed_at),
      inserted_at: iso(r.inserted_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ---- query helpers -------------------------------------------------------

  defp filter_workspace(query, ws) when ws in [nil, ""], do: query
  defp filter_workspace(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, started_at >= ^dt)

  # ---- param coercion ------------------------------------------------------

  defp parse_since(nil), do: {:ok, nil}
  defp parse_since(""), do: {:ok, nil}

  defp parse_since(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "since must be ISO8601 (e.g. 2026-06-01T00:00:00Z)"}}
    end
  end

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(""), do: {:ok, nil}

  defp parse_status(raw) when is_binary(raw) do
    valid = Record.statuses() |> Enum.map(&Atom.to_string/1)

    if raw in valid do
      {:ok, String.to_existing_atom(raw)}
    else
      {:error,
       {:invalid_request, "status must be one of: #{Enum.join(valid, ", ")}"}}
    end
  rescue
    ArgumentError ->
      {:error, {:invalid_request, "invalid status: #{inspect(raw)}"}}
  end

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(""), do: {:ok, @default_limit}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_limit)}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_limit)}
  defp parse_limit(_), do: {:error, {:invalid_request, "limit must be a positive integer"}}
end
