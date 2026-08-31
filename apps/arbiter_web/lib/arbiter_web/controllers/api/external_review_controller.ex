defmodule ArbiterWeb.Api.ExternalReviewController do
  @moduledoc """
  REST endpoint for the ExternalReview audit ledger (bd-31fh9e, bd-bs5b12).

  Route:

    * `GET /api/external_reviews` — list recent records, newest first, wrapped under the "data" key.
      Returns: `{"data": [...]}` (consistent with other /api collection endpoints).
      Note: the MCP `external_review_list` tool uses "external_reviews" instead (deliberate
      asymmetry — each transport follows its own convention per bd-bs5b12 Option 3).
      Optional query params:
        * `workspace_id` — restrict to one workspace.
        * `status`       — filter by `running` | `completed` | `failed`.
        * `since`        — ISO8601 lower bound on `started_at`.
        * `limit`        — max rows (default 50, max 500).

    * `GET /api/external_reviews/:id/transcript` — the durable corpus of one review
      (bd-7efini): the composed prompt, the raw stream-json transcript its reviewer
      emitted, and every tool call paired with the result it returned. The REST
      counterpart of `GET /api/workers/:task_id/log` for a review, which — not being
      task-linked — has no run row to look up. Wrapped under "data".
      Optional query params:
        * `tail`           — return only the last N transcript lines (`truncated`).
        * `include_prompt` — `false` to omit the (large) composed prompt.
      `exists: false` (200, empty `lines`) distinguishes "never captured" from
      "captured but empty"; only an unknown record id 404s.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Reviews.Record
  alias Arbiter.Reviews.Transcript
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

  def transcript(conn, %{"id" => id} = params) do
    with {:ok, tail} <- parse_tail(params["tail"]),
         {:ok, record} <- fetch_record(id) do
      summary = Transcript.summary(record.id)
      all_lines = read_lines(record.id)
      {lines, truncated} = tail_lines(all_lines, tail)

      json(conn, %{
        data: %{
          record_id: record.id,
          pr_ref: record.pr_ref,
          pr: record.pr,
          workspace_id: record.workspace_id,
          status: record.status,
          model: record.model,
          path: summary.path,
          prompt_path: summary.prompt_path,
          exists: summary.exists,
          prompt_exists: summary.prompt_exists,
          prompt: maybe_prompt(record.id, params["include_prompt"]),
          line_count: summary.line_count,
          lines: lines,
          truncated: truncated,
          tool_use_count: summary.tool_use_count,
          tools_used: summary.tools_used,
          tool_uses: Enum.map(Transcript.tool_uses(record.id), &render_tool_use/1)
        }
      })
    end
  end

  defp fetch_record(id) do
    case Ash.get(Record, id) do
      {:ok, %Record{} = record} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  defp read_lines(id) do
    case Transcript.read_lines(id) do
      {:ok, lines} -> lines
      {:error, _} -> []
    end
  end

  defp maybe_prompt(_id, "false"), do: nil
  defp maybe_prompt(_id, false), do: nil

  defp maybe_prompt(id, _) do
    case Transcript.prompt(id) do
      {:ok, prompt} -> prompt
      {:error, _} -> nil
    end
  end

  defp tail_lines(lines, nil), do: {lines, false}

  defp tail_lines(lines, n) do
    if length(lines) > n, do: {Enum.take(lines, -n), true}, else: {lines, false}
  end

  # A tool result is unbounded (a whole file, a repo-wide grep). Keep the
  # record of what ran and roughly what came back; the raw bytes stay on disk.
  @tool_result_preview 2_000

  defp render_tool_use(%{} = tool_use) do
    %{
      name: tool_use.name,
      tool_use_id: tool_use.tool_use_id,
      input: tool_use.input,
      result: truncate_preview(tool_use.result)
    }
  end

  defp truncate_preview(nil), do: nil

  defp truncate_preview(text) when is_binary(text) do
    if byte_size(text) > @tool_result_preview do
      binary_part(text, 0, @tool_result_preview) <> "… [truncated]"
    else
      text
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
      failure_stage: r.failure_stage,
      failure_reason: r.failure_reason,
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
      {:error, {:invalid_request, "status must be one of: #{Enum.join(valid, ", ")}"}}
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

  defp parse_tail(nil), do: {:ok, nil}
  defp parse_tail(""), do: {:ok, nil}

  defp parse_tail(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "tail must be a positive integer"}}
    end
  end

  defp parse_tail(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_tail(_), do: {:error, {:invalid_request, "tail must be a positive integer"}}
end
