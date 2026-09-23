defmodule Arbiter.Usage do
  @moduledoc """
  Ash domain + aggregation API for the structured token/cost usage ledger.

  Every Claude session — work worker, ReviewGate reviewer, or ReviewGate
  implementer — emits a final `result` event carrying tokens (input / output /
  cache), `total_cost_usd`, `duration_ms`, and model. The worker captures that
  and inserts an `Arbiter.Usage.Event` row keyed by task + step
  (`:work | :review | :impl`) + `workspace_id` (always the authoring task's
  workspace — see `Arbiter.Worker.effective_workspace_id/1` — even for
  reviewer/implementer rows, whose worker carries `workspace_id: nil` for
  unrelated notification-suppression reasons) and `worker_run_id` for
  joinability.

  Multiple rows per task are deliberate: a re-slung task writes a second
  `:work` row, a ReviewGate review adds a `:review` row, etc. Rework is then
  visible as the spend across rows for the same task.

  Not every row has a task, though. Since bd-adyhvn `task_id` is nullable and
  every row carries a `source` (`:task | :probe | :preflight |
  :coordinator_session | :terminal_session | :maintenance`), so the dispatch
  auth pre-flight and future coordinator / terminal sessions land here too —
  see `Arbiter.Usage.Event` and `Arbiter.Usage.Probe`. (`:probe` was the quota
  `RefreshProbe`'s source before it was deleted, bd-atyrrq — historical rows
  may still carry it.)

  ## Aggregation

  `summarize/1` rolls events up by one of `:day`, `:task`, `:epic`,
  `:workspace`, `:repo`, `:model`, `:step`, `:provider`, `:source`, or
  `:session`. It returns a list
  of maps with `{group:, total_cost_usd:, tokens_in:, tokens_out:, ...}`.
  `:campaign` (the old name for `:epic`) is still accepted as a deprecated
  alias — see `summarize/1` below.

  The CLI (`arb usage`) and Phoenix endpoint (`GET /api/usage`) sit on top of
  this. Anything new (per-day burn dashboards, budget routing) should call
  `summarize/1` rather than re-doing SQL.

  ## Estimation (bd-3j4ch4)

  `summarize/1` answers "what has been spent". `estimate_for_issue/2` answers
  the forward-looking question — "what will this task cost?" — from the same
  ledger, as a percentile range over comparable closed tasks, and
  `calibration/1` reports which closed tasks' actual costs say their
  difficulty rating was wrong. Both delegate to `Arbiter.Usage.Estimate`,
  which owns the window, the grouping ladder and the data-hygiene rules;
  they are re-exported here so callers have one door into the ledger.
  """

  use Ash.Domain

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event
  require Ash.Query

  resources do
    resource Arbiter.Usage.Event
  end

  @type group_by ::
          :day
          | :task
          | :epic
          | :workspace
          | :provider_account
          | :repo
          | :model
          | :step
          | :provider
          | :source
          | :session

  @type since :: DateTime.t() | nil

  @type rollup :: %{
          required(:group) => term(),
          required(:rows) => non_neg_integer(),
          required(:total_cost_usd) => float(),
          # bd-481sz7: false when every row in the group carries `cost_usd:
          # nil` (agy/Antigravity permanently does — a subscription metered
          # by quota %, not a priced API). Distinguishes "we know this cost
          # $0.00" from "we cannot price this at all" — callers must render
          # the latter as n/a, never as a dollar figure.
          required(:cost_known) => boolean(),
          required(:tokens_in) => non_neg_integer(),
          required(:tokens_out) => non_neg_integer(),
          required(:thinking_tokens) => non_neg_integer(),
          required(:cache_creation_tokens) => non_neg_integer(),
          required(:cache_read_tokens) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer(),
          # Meaningful only for `:by :session` groups. `estimated_event?/1`
          # reads `raw["arb_usage_source"]["cost_source"]`, which only
          # `Sessions.UsageIngest` ever stamps; the worker (`Worker`) and
          # `Reconciler` ingest paths never set `cost_source`, so every other
          # grouping (`:task`, `:day`, `:workspace`, …) always reports
          # `estimated: false` regardless of whether the underlying cost was a
          # real `cost-state`/API figure or an unmarked token-priced guess.
          # Read `false` there as "provenance unknown", not "exact".
          required(:estimated) => boolean()
        }

  @valid_by ~w(day task epic workspace provider_account repo model step provider source session)a

  # `campaign` was the old name for the `epic` grouping. Accepted as a
  # deprecated alias for one release; normalized to `:epic` before validation
  # so every caller (CLI, REST, MCP) gets the same grouping.
  @deprecated_by %{campaign: :epic}

  @doc """
  Roll up usage events into a list of summary rows.

  ## Options

    * `:by` — one of `#{inspect(@valid_by)}` (`:campaign` also accepted as a
      deprecated alias for `:epic`). Required.
    * `:since` — `%DateTime{}` filter on `occurred_at`. Optional.
    * `:workspace_id` — restrict to one workspace. Optional.
    * `:provider_account_id` — restrict to one provider account
      (`docs/provider-account-design.md` §3.3, §8). Filters
      `usage_events.provider_account_id` directly (P9), so it is exact with
      every grouping — including rows with no `workspace_id` at all (a probe
      or pre-flight row has no workspace but always has an account). Optional.
    * `:session_ids` — restrict to a list of `session_id` values, pushed into
      the query as `session_id in ^ids` rather than filtered after the read.
      `Event` indexes `:session_id`, so this keeps a `:by :session` rollup for
      a handful of known sessions (e.g. `/sessions`' live-refresh tick) an
      indexed lookup instead of a full-table read. Optional.
    * `:limit` — cap the returned rows (after sort). Optional.

  Returns `{:ok, [rollup]}` or `{:error, reason}`. Rows are sorted by
  `total_cost_usd` desc (or chronologically for `:by :day`).

  `:epic` groups by a task's `:parent_of` parent(s) — a task with more than
  one parent is counted in each, mirroring the parent-with-progress rollup.
  Tasks with *no* parent don't disappear; they fall into the catch-all sentinel
  `(no_epic)` so spend isn't silently lost.

  ## Task-less rows (bd-adyhvn)

  Rows whose `source` isn't `:task` carry a `nil` `task_id` — quota probes,
  auth pre-flights, coordinator / terminal sessions. `:task` is the one
  grouping that **drops** them: a rollup keyed by task must not grow a `nil`
  or sentinel group for spend that belongs to no task. Every other grouping
  counts them, so `:day`, `:workspace`, `:provider` and `:source` totals are
  the real consumption. Use `:source` to see the split.

  `:session` is the mirror image of `:task`: it groups by `session_id` and
  **drops** rows that carry none (i.e. everything but `coordinator_session` /
  `terminal_session` sources), the same "don't invent a phantom group"
  discipline `:task` already applies (§7.6 of
  `docs/browser-hosted-coordinator-sessions.md`).
  """
  @spec summarize(keyword()) :: {:ok, [rollup()]} | {:error, term()}
  def summarize(opts) when is_list(opts) do
    with {:ok, by} <- fetch_by(opts) do
      events =
        Event
        |> base_filter(opts)
        |> Ash.read!()

      {:ok,
       events
       |> group_events(by)
       |> Enum.map(&aggregate_group(by, &1))
       |> sort_rollups(by)
       |> maybe_limit(opts)}
    end
  end

  # Providers that record `usage_events` rows for internal bookkeeping (e.g.
  # `Arbiter.Loop.Corpus.record_pass_cost/1` writes `provider: "arbiter"` for
  # loop-pass cost with no token counts) rather than by parsing an agent CLI's
  # stream. They have no stream parser to fail, so they are always
  # zero-token by design and must not trip the blindness detector below.
  @synthetic_providers ~w(arbiter)

  @doc """
  Providers whose `usage_events` rows are **wholly** zero-or-unknown-token
  over the window — i.e. no row for that provider carries any reported
  token count.

  A provider whose stream parser silently drops usage (bd-2fzwlc: this is
  exactly what happened to every Gemini/agy row before the fix) reads
  identically to "that provider is just cheap" unless something calls this
  out. A provider with even one row carrying real tokens is not flagged —
  this is a blindness detector, not a low-usage alert.

  Every flagged row is one of two shapes, counted separately (bd-96mn8i
  round 2, finding 3):

    * **literal zero** (`zero_rows`) — `tokens_in`/`tokens_out` are both the
      number `0`. This is the actual "parser bug" signature: the provider's
      stream reported a terminal event and the parser read nothing out of
      it.
    * **unknown** (`unknown_rows`) — `tokens_in`/`tokens_out` are both `nil`,
      meaning no usage was recorded at all (e.g. a failed probe that never
      reached a terminal event). This is an honest gap, not a parser bug,
      and callers must word it differently — folding it into "zero" here is
      exactly the bug this function exists to catch, one level up: after
      bd-96mn8i's fix, a window of legitimately-failed probes would
      otherwise re-raise "likely a stream parser silently dropping usage"
      against data that is already correct.

  Accepts the same `:since` / `:workspace_id` options as `summarize/1`, plus
  `:until` (`%DateTime{}`, filters `occurred_at <= until`) so a historical
  window's flag reflects only the rows the window actually covers.
  Returns `{:ok, [%{provider:, rows:, zero_rows:, unknown_rows:}]}`, sorted
  by provider name.
  """
  @spec zero_token_providers(keyword()) :: {:ok, [zero_token_report()]}
  def zero_token_providers(opts \\ []) do
    events =
      Event
      |> base_filter(opts)
      |> Ash.read!()

    flagged =
      events
      |> Enum.group_by(&(&1.provider || "(unknown)"))
      |> Enum.reject(fn {provider, _evs} -> provider in @synthetic_providers end)
      |> Enum.filter(fn {_provider, evs} ->
        Enum.all?(evs, &(zero_tokens?(&1) or unknown_usage?(&1)))
      end)
      |> Enum.map(fn {provider, evs} ->
        %{
          provider: provider,
          rows: length(evs),
          zero_rows: Enum.count(evs, &zero_tokens?/1),
          unknown_rows: Enum.count(evs, &unknown_usage?/1)
        }
      end)
      |> Enum.sort_by(& &1.provider)

    {:ok, flagged}
  end

  @typedoc "One flagged provider's row breakdown — see `zero_token_providers/1`."
  @type zero_token_report :: %{
          provider: String.t(),
          rows: pos_integer(),
          zero_rows: non_neg_integer(),
          unknown_rows: non_neg_integer()
        }

  # A row that reports actual, known-zero usage — both fields present and
  # literally `0`. `nil == 0` is false in Elixir, so this never matches an
  # unknown row.
  defp zero_tokens?(ev), do: ev.tokens_in == 0 and ev.tokens_out == 0

  # A row that reports no usage at all — the honest "we don't know" case.
  defp unknown_usage?(ev), do: is_nil(ev.tokens_in) and is_nil(ev.tokens_out)

  @doc """
  Percentile cost estimate for an issue — see `Arbiter.Usage.Estimate.for_issue/2`.
  """
  @spec estimate_for_issue(Arbiter.Tasks.Issue.t() | String.t(), keyword()) ::
          Estimate.t() | :insufficient_data
  defdelegate estimate_for_issue(issue_or_id, opts \\ []), to: Estimate, as: :for_issue

  @doc """
  Difficulty mis-rating report — see `Arbiter.Usage.Estimate.calibration/1`.
  """
  @spec calibration(keyword()) :: map()
  defdelegate calibration(opts \\ []), to: Estimate

  @doc """
  Epic cost rollup ("$X spent · ~$Y–Z to go") — see
  `Arbiter.Usage.Estimate.epic_cost_rollup/2`.
  """
  @spec epic_cost_rollup(Arbiter.Tasks.Issue.t() | String.t(), keyword()) :: map() | nil
  defdelegate epic_cost_rollup(issue_or_id, opts \\ []), to: Estimate

  @spec valid_groupings() :: [group_by()]
  def valid_groupings, do: @valid_by

  @doc """
  Groupings acceptable as input, including deprecated aliases (e.g.
  `:campaign`). Callers that parse a raw `by` string/atom before calling
  `summarize/1` (the REST controller, the MCP tool) should validate against
  this list rather than `valid_groupings/0`, then pass the raw atom through —
  `summarize/1` normalizes it.
  """
  @spec acceptable_groupings() :: [atom()]
  def acceptable_groupings, do: @valid_by ++ Map.keys(@deprecated_by)

  @doc "Normalize a deprecated alias (e.g. `:campaign`) to its canonical grouping."
  @spec normalize_by(atom()) :: group_by()
  def normalize_by(by), do: Map.get(@deprecated_by, by, by)

  # ---- aggregation -------------------------------------------------------

  defp fetch_by(opts) do
    case Keyword.fetch(opts, :by) do
      {:ok, by} ->
        case normalize_by(by) do
          norm when norm in @valid_by -> {:ok, norm}
          _ -> {:error, {:invalid_grouping, by}}
        end

      :error ->
        {:error, :missing_grouping}
    end
  end

  defp base_filter(query, opts) do
    query
    |> filter_since(Keyword.get(opts, :since))
    |> filter_until(Keyword.get(opts, :until))
    |> filter_workspace_id(Keyword.get(opts, :workspace_id))
    |> filter_provider_account_id(Keyword.get(opts, :provider_account_id))
    |> filter_session_ids(Keyword.get(opts, :session_ids))
  end

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at >= ^dt)

  defp filter_until(query, nil), do: query
  defp filter_until(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at <= ^dt)

  defp filter_workspace_id(query, nil), do: query
  defp filter_workspace_id(query, ""), do: query
  defp filter_workspace_id(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_provider_account_id(query, nil), do: query
  defp filter_provider_account_id(query, ""), do: query

  defp filter_provider_account_id(query, account_id),
    do: Ash.Query.filter(query, provider_account_id == ^account_id)

  defp filter_session_ids(query, nil), do: query
  defp filter_session_ids(query, []), do: query

  defp filter_session_ids(query, ids) when is_list(ids),
    do: Ash.Query.filter(query, session_id in ^ids)

  # Group events by the requested dimension. For :epic we resolve each
  # event's task's `:parent_of` parents at read time (a join would be cleaner
  # but the data volume is small for now; this is plain in-memory grouping).
  defp group_events(events, :day) do
    Enum.group_by(events, fn ev -> Date.to_iso8601(DateTime.to_date(ev.occurred_at)) end)
  end

  # bd-adyhvn: only task-attributed rows. A probe / pre-flight / session row
  # has no task, and grouping it under `nil` (or a synthetic sentinel) is
  # exactly the phantom-task pollution this grouping has to stay free of.
  # Nothing is lost — `:source` and `:day` still count those rows.
  defp group_events(events, :task) do
    events
    |> Enum.filter(&task_attributed?/1)
    |> Enum.group_by(& &1.task_id)
  end

  defp group_events(events, :source),
    do: Enum.group_by(events, &Atom.to_string(&1.source || :task))

  # Mirrors `:task`'s exclusion above: a row with no `session_id` belongs to
  # no session, so it is dropped rather than grouped under a `nil` sentinel.
  defp group_events(events, :session) do
    events
    |> Enum.filter(&session_attributed?/1)
    |> Enum.group_by(& &1.session_id)
  end

  defp group_events(events, :workspace),
    do: Enum.group_by(events, &(&1.workspace_id || "(none)"))

  # §5 row 14, §8: the account rollup, read straight off
  # `usage_events.provider_account_id` (P9). This is what makes probe/
  # pre-flight rows count — they carry no `workspace_id` but always carry
  # `provider_account_id` (§8's seam with bd-adyhvn) — dropping them here
  # would reintroduce the exact under-reporting bias bd-adyhvn measured.
  # Rows with no resolvable account fall into the `(none)` sentinel rather
  # than vanishing.
  defp group_events(events, :provider_account) do
    Enum.group_by(events, &(&1.provider_account_id || "(none)"))
  end

  defp group_events(events, :repo), do: Enum.group_by(events, &(&1.repo || "(none)"))
  defp group_events(events, :model), do: Enum.group_by(events, &(&1.model || "(unknown)"))
  defp group_events(events, :provider), do: Enum.group_by(events, &(&1.provider || "(unknown)"))
  defp group_events(events, :step), do: Enum.group_by(events, &Atom.to_string(&1.step))

  defp group_events(events, :epic) do
    parents = load_parent_edges(events)

    Enum.reduce(events, %{}, fn ev, acc ->
      base_task = base_task_id(ev.task_id)

      case Map.get(parents, base_task, []) do
        [] -> Map.update(acc, "(no_epic)", [ev], &[ev | &1])
        ids -> Enum.reduce(ids, acc, fn pid, a -> Map.update(a, pid, [ev], &[ev | &1]) end)
      end
    end)
  end

  defp task_attributed?(ev), do: is_binary(ev.task_id) and ev.task_id != ""
  defp session_attributed?(ev), do: is_binary(ev.session_id) and ev.session_id != ""

  # Drop any ReviewGate synthetic-id suffix (`#review`, `#r2`, ...) so a
  # review event is still attributable to the author task for epic lookup.
  # A task-less row (bd-adyhvn) has nothing to strip and no epic — it falls
  # into the `(no_epic)` catch-all so its spend is still counted there.
  def base_task_id(nil), do: nil
  defdelegate base_task_id(task_id), to: Arbiter.Worker.ReviewGate

  # Map each event's task to the parent task(s) it hangs under via `:parent_of`
  # edges (the task is the `to_issue`; its parents are the `from_issue`s).
  defp load_parent_edges(events) do
    parent_of = :parent_of

    task_ids =
      events
      |> Enum.map(&base_task_id(&1.task_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case task_ids do
      [] ->
        %{}

      ids ->
        Dependency
        |> Ash.Query.filter(type == ^parent_of and to_issue_id in ^ids)
        |> Ash.read!()
        |> Enum.reduce(%{}, fn d, acc ->
          Map.update(acc, d.to_issue_id, [d.from_issue_id], &[d.from_issue_id | &1])
        end)
    end
  rescue
    _ -> %{}
  end

  defp aggregate_group(_by, {group, events}) do
    init = %{
      group: group,
      rows: 0,
      total_cost_usd: 0.0,
      cost_known: false,
      tokens_in: 0,
      tokens_out: 0,
      thinking_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      duration_ms: 0,
      estimated: false
    }

    Enum.reduce(events, init, &merge_event/2)
  end

  defp merge_event(ev, acc) do
    %{
      acc
      | rows: acc.rows + 1,
        total_cost_usd: add(acc.total_cost_usd, ev.cost_usd),
        cost_known: acc.cost_known || known?(ev.cost_usd),
        tokens_in: add(acc.tokens_in, ev.tokens_in),
        tokens_out: add(acc.tokens_out, ev.tokens_out),
        thinking_tokens: add(acc.thinking_tokens, ev.thinking_tokens),
        cache_creation_tokens: add(acc.cache_creation_tokens, ev.cache_creation_tokens),
        cache_read_tokens: add(acc.cache_read_tokens, ev.cache_read_tokens),
        duration_ms: add(acc.duration_ms, ev.duration_ms),
        estimated: acc.estimated || estimated_event?(ev)
    }
  end

  defp add(total, nil), do: total
  defp add(total, n), do: total + n

  defp known?(nil), do: false
  defp known?(_), do: true

  # `Sessions.UsageIngest` stamps `raw["arb_usage_source"]["cost_source"]`
  # with the same `:cost_state | :estimated | none` provenance
  # `ClaudeSessionFile` reports live (see `ClaudePricing`'s moduledoc) — this
  # is the persisted mirror of that marker, so a rollup can carry it forward
  # without recomputing an estimate itself.
  defp estimated_event?(%{raw: %{"arb_usage_source" => %{"cost_source" => "estimated"}}}),
    do: true

  defp estimated_event?(_ev), do: false

  defp sort_rollups(rollups, :day), do: Enum.sort_by(rollups, & &1.group)

  defp sort_rollups(rollups, _by),
    do: Enum.sort_by(rollups, &(-(&1.total_cost_usd || 0.0)))

  defp maybe_limit(rollups, opts) do
    case Keyword.get(opts, :limit) do
      n when is_integer(n) and n > 0 -> Enum.take(rollups, n)
      _ -> rollups
    end
  end
end
