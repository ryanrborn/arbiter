defmodule ArbiterWeb.Api.UsageController do
  @moduledoc """
  REST endpoints for the structured usage ledger (`Arbiter.Usage.Event`).

  Routes:

    * `GET /api/usage`          — aggregated rollup. Required query: `by` (one of
                                  `day | task | epic | workspace |
                                  provider_account | repo | model | step |
                                  provider | source | session`; `campaign`
                                  also accepted as a deprecated alias for
                                  `epic`, and `account` accepted as an alias
                                  for `provider_account`). Optional:
                                  `workspace_id`, `account`, `since`
                                  (ISO8601), `limit`.
    * `GET /api/usage/events`   — raw event list (newest first). Optional
                                  filters: `workspace_id`, `account`, `task_id`,
                                  `session_id`, `since`, `step`, `source`,
                                  `limit` (default 50).
    * `GET /api/usage/calibration` — difficulty mis-rating report (bd-3j4ch4):
                                  closed tasks whose actual cost lands outside
                                  their own tier's p25–p75 but inside an
                                  adjacent tier's. Optional: `workspace_id`,
                                  `window_days`.

  `by=task` covers task-attributed spend only — probe / pre-flight / session
  rows carry no `task_id` (bd-adyhvn). Use `by=source` for the full split.

  `account` (P10, `docs/provider-account-design.md` §8) accepts anything
  `Arbiter.Accounts.get_account/1` resolves — a UUID, a `"provider:slug"`
  ref, or a bare unambiguous slug — and filters
  `usage_events.provider_account_id` directly (P9), so probe/pre-flight rows
  (no `workspace_id`, but always an account) are included. `by=provider_account`
  is the rollup dimension; `account` narrows any rollup or the raw event list
  to one account.

  Both back the `arb usage` CLI; the rollup is the primary surface (per-day
  spend, top tasks, rework cost). `events` is for debugging / drill-down.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Usage
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_event_limit 50

  def summarize(conn, params) do
    with {:ok, by} <- parse_by(params["by"]),
         {:ok, since} <- parse_since(params["since"]),
         {:ok, limit} <- parse_optional_limit(params["limit"]),
         {:ok, account_id} <- parse_account(params["account"]) do
      opts =
        [by: by]
        |> add_opt(:since, since)
        |> add_opt(:workspace_id, params["workspace_id"])
        |> add_opt(:provider_account_id, account_id)
        |> add_opt(:limit, limit)

      case Usage.summarize(opts) do
        {:ok, rollups} ->
          json(conn, %{
            by: Atom.to_string(Usage.normalize_by(by)),
            data: Enum.map(rollups, &render_rollup/1)
          })

        {:error, reason} ->
          {:error, {:invalid_request, "could not summarize usage: #{inspect(reason)}"}}
      end
    end
  end

  @doc """
  The mis-rating report behind `arb usage --calibration`.

  Rendered wholesale rather than paginated: the flagged list is the tasks
  whose rating looks wrong, which is a handful even over a busy 60 days, and
  truncating it would silently hide the tail that matters most.
  """
  def calibration(conn, params) do
    with {:ok, window_days} <- parse_window_days(params["window_days"]) do
      opts =
        []
        |> add_opt(:workspace_id, params["workspace_id"])
        |> add_opt(:window_days, window_days)

      report = Estimate.calibration(opts)

      json(conn, %{
        window_days: report.window_days,
        re_dispatched_flagged: report.re_dispatched_flagged,
        tiers: Enum.map(report.tiers, &render_tier/1),
        flagged: Enum.map(report.flagged, &render_flag/1)
      })
    end
  end

  def events(conn, params) do
    with {:ok, since} <- parse_since(params["since"]),
         {:ok, step} <- parse_step(params["step"]),
         {:ok, source} <- parse_source(params["source"]),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, account_id} <- parse_account(params["account"]) do
      events =
        Event
        |> filter_eq(:workspace_id, params["workspace_id"])
        |> filter_eq(:provider_account_id, account_id)
        |> filter_eq(:task_id, params["task_id"])
        |> filter_eq(:session_id, params["session_id"])
        |> filter_eq(:step, step)
        |> filter_eq(:source, source)
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
      # nil (not 0.0) when no row in the group ever priced a cost — see
      # `Arbiter.Usage.summarize/1`'s `cost_known` (bd-481sz7). A $0.00 here
      # would misreport an agy/Antigravity subscription (no dollar figure,
      # ever) as a session that happened to cost nothing.
      total_cost_usd: if(r.cost_known, do: round_money(r.total_cost_usd)),
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      thinking_tokens: r.thinking_tokens,
      cache_creation_tokens: r.cache_creation_tokens,
      cache_read_tokens: r.cache_read_tokens,
      duration_ms: r.duration_ms
    }
  end

  defp render_tier(tier) do
    %{
      difficulty: tier.difficulty,
      n: tier.n,
      n_scored: tier.n_scored,
      re_dispatched: tier.re_dispatched,
      p25: round_money(tier.p25),
      median: round_money(tier.median),
      p75: round_money(tier.p75),
      p90: round_money(tier.p90),
      under_rated: tier.under_rated,
      over_rated: tier.over_rated,
      under_rate: tier.under_rate,
      over_rate: tier.over_rate
    }
  end

  defp render_flag(flag) do
    %{
      task_id: flag.task_id,
      title: flag.title,
      difficulty: flag.difficulty,
      issue_type: render_group(flag.issue_type),
      actual_cost_usd: round_money(flag.actual_cost_usd),
      direction: Atom.to_string(flag.direction),
      suggested_difficulty: flag.suggested_difficulty,
      re_dispatched: flag.re_dispatched
    }
  end

  defp render_group(nil), do: nil
  defp render_group(g) when is_binary(g), do: g
  defp render_group(g) when is_atom(g), do: Atom.to_string(g)
  defp render_group(g), do: inspect(g)

  defp render_event(%Event{} = ev) do
    %{
      id: ev.id,
      task_id: ev.task_id,
      source: Atom.to_string(ev.source || :task),
      workspace_id: ev.workspace_id,
      repo: ev.repo,
      step: Atom.to_string(ev.step),
      model: ev.model,
      provider: ev.provider,
      tokens_in: ev.tokens_in,
      tokens_out: ev.tokens_out,
      thinking_tokens: ev.thinking_tokens,
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

  defp filter_eq(query, :provider_account_id, v),
    do: Ash.Query.filter(query, provider_account_id == ^v)

  defp filter_eq(query, :task_id, v) do
    prefix = v <> "#%"
    Ash.Query.filter(query, task_id == ^v or like(task_id, ^prefix))
  end

  defp filter_eq(query, :session_id, v), do: Ash.Query.filter(query, session_id == ^v)

  defp filter_eq(query, :step, v), do: Ash.Query.filter(query, step == ^v)
  defp filter_eq(query, :source, v), do: Ash.Query.filter(query, source == ^v)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at >= ^dt)

  # ---- param coercion ----------------------------------------------------

  defp parse_by(nil), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}
  defp parse_by(""), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}

  defp parse_by(raw) when is_binary(raw) do
    atom = String.to_existing_atom(raw)

    if atom in Usage.acceptable_groupings() do
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
    atom = String.to_existing_atom(raw)

    if atom in Event.steps() do
      {:ok, atom}
    else
      {:error, {:invalid_request, "invalid step: #{inspect(raw)}"}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_request, "invalid step: #{inspect(raw)}"}}
  end

  defp parse_source(nil), do: {:ok, nil}
  defp parse_source(""), do: {:ok, nil}

  defp parse_source(raw) when is_binary(raw) do
    atom = String.to_existing_atom(raw)

    if atom in Event.sources() do
      {:ok, atom}
    else
      {:error, {:invalid_request, "invalid source: #{inspect(raw)}"}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_request, "invalid source: #{inspect(raw)}"}}
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

  defp parse_window_days(nil), do: {:ok, nil}
  defp parse_window_days(""), do: {:ok, nil}

  defp parse_window_days(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "window_days must be a positive integer"}}
    end
  end

  defp parse_window_days(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_window_days(_),
    do: {:error, {:invalid_request, "window_days must be a positive integer"}}

  defp parse_optional_limit(nil), do: {:ok, nil}
  defp parse_optional_limit(""), do: {:ok, nil}
  defp parse_optional_limit(raw), do: parse_limit(raw)

  # `?account=` resolves the same way `arb account` refs do — a UUID, a
  # `"provider:slug"` ref, or a bare unambiguous slug — to an account id, so
  # `usage_events.provider_account_id` can be filtered directly (P9).
  defp parse_account(nil), do: {:ok, nil}
  defp parse_account(""), do: {:ok, nil}

  defp parse_account(ref) when is_binary(ref) do
    case Arbiter.Accounts.get_account(ref) do
      {:ok, account} ->
        {:ok, account.id}

      {:error, :not_found} ->
        {:error, {:invalid_request, "account #{inspect(ref)} not found"}}

      {:error, :ambiguous} ->
        {:error,
         {:invalid_request, "account #{inspect(ref)} is ambiguous; use \"provider:slug\""}}
    end
  end
end
