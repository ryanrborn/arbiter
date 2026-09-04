defmodule ArbiterWeb.Api.LoopController do
  @moduledoc """
  REST surface for the loop-analysis pass (Stage 1, bd-dyfaq3) and its
  reviewable-proposal queue (Stage 2, bd-9j2g3x).

    * `GET /api/loop/analyze` — run the operator-invoked loop-analysis pass over
      a window and return its markdown report. Optional query params: `since`
      (`7d` / `24h` / `30m` shortcuts or ISO8601; default: last 7 days), `until`
      (ISO8601; default now), `limit` (cap on runs scanned, newest first),
      `workspace_id`, `label`.
    * `POST /api/loop/propose` — the same pass, plus persistence of the
      proposals it implies. Same params.
    * `POST /api/loop/propose/repo_doc_patch` — hand-author a `:repo_doc_patch`
      proposal directly: `repo` + `lesson` (required), optional `category` /
      `workspace_id`. The Stage 1 pass cannot attribute a finding category to
      one repo yet, so this is the entry point onto that write path today.
    * `GET  /api/loop/pending` — list queued proposals. Optional `state` (one
      name or a comma-separated list; default the two live states), `kind`,
      `workspace_id`, `limit`.
    * `GET  /api/loop/pending/:id` — one proposal, including its unified `diff`.
    * `POST /api/loop/pending/:id/apply` — apply it through the same public
      domain API a human would use.
    * `POST /api/loop/pending/:id/reject` — soft-reject it (optional `reason`).

  `GET /api/loop/analyze` is **report-only**: it writes nothing but its own
  `usage_events` cost row (`Arbiter.Loop.Analysis`). Persisting proposals is a
  separate verb on a separate route, so the read-only guarantee is structural
  rather than a flag on a GET. Backs the `arb loop` CLI.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Loop
  alias Arbiter.Loop.Analysis

  action_fallback(ArbiterWeb.Api.FallbackController)

  # Attribution label for decisions arriving over the REST/CLI surface.
  @actor "cli"

  def analyze(conn, params), do: run_analysis(conn, params, propose?: false)

  def propose(conn, params), do: run_analysis(conn, params, propose?: true)

  # bd-1cusio: the Stage 1 pass cannot yet attribute a finding category to one
  # repo (Arbiter.Loop.Proposals leaves `repo: nil` on every `:claude_md`
  # destination), so this is the production entry point onto the
  # `:repo_doc_patch` write path today — an operator names the repo and the
  # lesson text directly. See `Arbiter.Loop.propose_repo_doc_patch/1`.
  def propose_repo_doc_patch(conn, params) do
    attrs = %{
      repo: params["repo"],
      lesson: params["lesson"],
      category: blank_to_nil(params["category"]),
      workspace_id: blank_to_nil(params["workspace_id"]),
      actor: @actor
    }

    case Loop.propose_repo_doc_patch(attrs) do
      {:ok, row} -> json(conn, %{pending: render_pending(row, :full)})
      {:error, reason} -> {:error, apply_error(reason)}
    end
  end

  defp run_analysis(conn, params, propose?: propose?) do
    with {:ok, since} <- parse_window(params["since"]),
         {:ok, until} <- parse_iso(params["until"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      opts =
        [propose?: propose?]
        |> put(:since, since)
        |> put(:until, until)
        |> put(:limit, limit)
        |> put(:workspace_id, blank_to_nil(params["workspace_id"]))
        |> put(:label, blank_to_nil(params["label"]))

      case Analysis.analyze(opts) do
        {:ok, %{markdown: markdown, report: report, usage_event_id: uid} = envelope} ->
          json(
            conn,
            maybe_put_proposals(
              %{markdown: markdown, usage_event_id: uid, summary: summary(report)},
              envelope
            )
          )

        {:error, reason} ->
          {:error, {:invalid_request, "loop analysis failed: #{inspect(reason)}"}}
      end
    end
  end

  # `:proposals` (and `:proposals_dropped`) are only present when the caller
  # opted in, so the analyze response body is byte-identical to what it was
  # before Stage 2. `:proposals_dropped` (bd-3dasqm) surfaces a candidate
  # `record/2` refused — e.g. an ambiguous install with no unambiguous
  # workspace to attribute a fleet finding to — instead of it only ever
  # showing up in a log line.
  defp maybe_put_proposals(body, %{proposals: rows} = envelope) do
    dropped = Map.get(envelope, :proposals_dropped, [])

    body
    |> Map.put(:proposals, Enum.map(rows, &render_pending/1))
    |> Map.put(
      :proposals_dropped,
      Enum.map(dropped, &%{gist: &1.gist, reason: inspect(&1.reason)})
    )
  end

  defp maybe_put_proposals(body, _envelope), do: body

  # ---- the proposal queue -------------------------------------------------

  def pending_index(conn, params) do
    with {:ok, states} <- parse_states(params["state"]),
         {:ok, kind} <- parse_kind(params["kind"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      rows =
        []
        |> put(:state, states || Loop.live_states())
        |> put(:kind, kind)
        |> put(:workspace_id, blank_to_nil(params["workspace_id"]))
        |> put(:limit, limit)
        |> Loop.list_pending()

      json(conn, %{
        pending: Enum.map(rows, &render_pending/1),
        evidence_bar: Loop.evidence_bar(blank_to_nil(params["workspace_id"]))
      })
    end
  end

  def pending_show(conn, %{"id" => id}) do
    with {:ok, row} <- Loop.get_pending(id) do
      json(conn, %{pending: render_pending(row, :full)})
    end
  end

  def pending_apply(conn, %{"id" => id}) do
    case Loop.apply_pending(id, actor: @actor) do
      {:ok, row} -> json(conn, %{pending: render_pending(row, :full), applied: true})
      {:error, reason} -> {:error, apply_error(reason)}
    end
  end

  def pending_reject(conn, %{"id" => id} = params) do
    opts = [actor: @actor] |> put(:reason, blank_to_nil(params["reason"]))

    case Loop.reject_pending(id, opts) do
      {:ok, row} -> json(conn, %{pending: render_pending(row, :full), rejected: true})
      {:error, reason} -> {:error, apply_error(reason)}
    end
  end

  defp apply_error(:not_found), do: :not_found

  defp apply_error({code, message}) when is_atom(code) and is_binary(message),
    do: {:invalid_request, message, %{code: to_string(code)}}

  defp apply_error(other), do: {:invalid_request, "loop proposal failed: #{inspect(other)}"}

  defp render_pending(row, detail \\ :summary)

  defp render_pending(row, :summary) do
    %{
      id: row.id,
      kind: row.kind,
      state: row.state,
      scope: row.scope,
      gist: row.gist,
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks,
      context_cost_tokens: row.context_cost_tokens,
      target: row.target,
      category: row.category,
      applicable: Loop.applicable?(row),
      created_at: row.created_at,
      updated_at: row.updated_at
    }
  end

  defp render_pending(row, :full) do
    row
    |> render_pending(:summary)
    |> Map.merge(%{
      diff: row.diff,
      payload: row.payload,
      target_metric: row.target_metric,
      baseline: row.baseline,
      incident_refs: row.incident_refs,
      task_refs: row.task_refs,
      fingerprint: row.fingerprint,
      origin: row.origin,
      workspace_id: row.workspace_id,
      applied_at: row.applied_at,
      escalated_at: row.escalated_at,
      rejection_reason: row.rejection_reason,
      inapplicable_reason: Loop.inapplicable_reason(row)
    })
  end

  # A compact structured summary alongside the markdown, for programmatic callers.
  defp summary(report) do
    %{
      window: report.window[:label],
      totals: report.totals,
      misclassification_rate: report.misclassification[:rate],
      finding_categories: length(report.finding_categories),
      finding_residue: finding_residue_summary(report.finding_residue),
      difficulty_misestimates: length(report.difficulty_misestimates),
      fleet_wide_suggestions: Enum.count(report.suggestions, &(&1.verdict == :fleet_wide))
    }
  end

  # bd-5ja2vb: the count/rate/distinct-task shape, without the retained
  # `units` sample (potentially hundreds of finding-text strings) — that
  # belongs to the in-process `Report` a future backfill pass reads, not the
  # compact summary a CLI/dashboard renders.
  defp finding_residue_summary(fr) do
    %{
      total_units: Map.get(fr, :total_units, 0),
      count: Map.get(fr, :count, 0),
      rate: Map.get(fr, :rate),
      distinct_tasks: Map.get(fr, :distinct_tasks, 0)
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
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        {:error,
         {:invalid_request, "expected ISO8601 or a 7d/24h/30m shortcut, got #{inspect(raw)}"}}
    end
  end

  # `state=` accepts one name or a comma-separated list; absent means the two
  # live states (an operator wants the queue, not the archive). Unknown names are
  # rejected rather than silently dropped, so a typo can't look like an empty
  # queue.
  @states ~w(proposed hypothesis applied rejected superseded)
  @kinds ~w(skill_patch skill_create difficulty_override config_set repo_doc_patch)

  defp parse_states(nil), do: {:ok, nil}
  defp parse_states(""), do: {:ok, nil}

  defp parse_states(raw) when is_binary(raw) do
    names =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.reject(names, &(&1 in @states)) do
      [] when names == [] ->
        {:ok, nil}

      [] ->
        {:ok, Enum.map(names, &String.to_existing_atom/1)}

      bad ->
        {:error,
         {:invalid_request,
          "unknown state(s) #{inspect(bad)}; expected one of #{Enum.join(@states, ", ")}"}}
    end
  end

  defp parse_states(other) do
    {:error, {:invalid_request, "state must be a string, got #{inspect(other)}"}}
  end

  defp parse_kind(nil), do: {:ok, nil}
  defp parse_kind(""), do: {:ok, nil}

  defp parse_kind(raw) when is_binary(raw) do
    if raw in @kinds do
      {:ok, String.to_existing_atom(raw)}
    else
      {:error,
       {:invalid_request,
        "unknown kind #{inspect(raw)}; expected one of #{Enum.join(@kinds, ", ")}"}}
    end
  end

  defp parse_kind(other) do
    {:error, {:invalid_request, "kind must be a string, got #{inspect(other)}"}}
  end

  # `limit` arrives as a string on the GET query-string routes and as a real
  # integer in the JSON body of `POST /api/loop/propose` (`arb loop analyze
  # --propose --limit N` sends `%{"limit" => 50}`), so both shapes are accepted
  # and anything else is a 400 rather than a FunctionClauseError 500.
  defp parse_limit(nil), do: {:ok, nil}
  defp parse_limit(""), do: {:ok, nil}
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(_other), do: {:error, {:invalid_request, "limit must be a positive integer"}}

  defp unit_seconds("d"), do: 24 * 3600
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("m"), do: 60

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
