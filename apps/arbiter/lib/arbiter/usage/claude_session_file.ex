defmodule Arbiter.Usage.ClaudeSessionFile do
  @moduledoc """
  Read token usage back out of Claude Code's **on-disk session JSONL** — a
  fallback/audit source for the `Arbiter.Usage.Event` ledger.

  ## Why this exists

  The primary usage path is `Arbiter.Worker.record_usage_event/3`, which parses
  the Claude CLI's `--output-format stream-json` stdout for the terminal
  `result` event (already-correct cumulative tokens + cost). That path is
  load-bearing and unchanged.

  But it depends on the process living long enough to emit a clean `result`
  event on stdout. A worker whose agent is **killed / crashes** before that
  terminal event — or a node that dies mid-run — leaves the stdout ledger row
  with no token numbers (or no row at all). The Claude CLI *also* persists every
  turn's usage to a session JSONL on disk that survives regardless of how the
  process died, so we can reconcile the missed usage from there. This module is
  that reader. It is deliberately **Claude-Code-specific** — no multi-provider
  `Provider` behaviour until a second provider actually needs one (bd-au3xrq).

  ## On-disk layout (confirmed against Claude Code 2.1.219)

  The CLI writes one file per session at:

      <config_dir>/projects/<project-slug>/<session-id>.jsonl

  where `config_dir` is the effective `CLAUDE_CONFIG_DIR` (workers run with an
  isolated `~/.cache/arbiter/worker-claude`, not the default `~/.claude` — see
  `Arbiter.Agents.Claude.ConfigDir`), and `project-slug` is the worker's cwd
  with **every non-alphanumeric character replaced by `-`** (so `/` and `.` and
  `_` all become `-`; letter case is preserved). Each line is one JSON event;
  `assistant`-type lines carry `message.usage` with the per-turn token buckets.

  Because a session id is a globally-unique UUID, `locate/2` finds the file by
  globbing `projects/*/<session-id>.jsonl` under the config dir — no need to
  reconstruct the slug (though `project_slug/1` is exposed for the exact path).

  ## Streaming duplication (the one gotcha)

  Multiple consecutive `assistant` lines can share an identical `message.id`
  with identical `usage` — these are streaming re-emits of the same turn's
  running snapshot, not incremental deltas. Naively summing every line
  double-counts (~2x). `read_totals/2` dedupes by `message.id`, keep-first,
  before summing — matching the spike's prototype (bd-abog97).

  ## One file, several runs (`--resume`) — use `:since`

  `Arbiter.Worker.Dispatch.resume_session/2` re-spawns with `--resume <sid>`
  (no `--fork-session`), and the CLI **appends to the same `<sid>.jsonl`**. But
  Arbiter opens a *new* `Workers.Run` row for the resumed attempt, so one file
  legitimately spans two (or more) runs — reading the whole file for the child
  run would bill it for every token the parent already spent (observed in the
  production ledger: resumed runs whose parent's file holds ~100x the child's
  own usage).

  So every line carries an ISO8601 `timestamp`, and `read_totals/2` takes a
  `:since` cutoff: only turns at-or-after it are summed. Callers pass the
  *run's* start (`session.started_at` in the worker, `run.started_at` in the
  reconciler), which bounds the read to that run's own turns. A turn first seen
  *before* the cutoff is remembered as already-counted, so a streaming re-emit
  landing after the cutoff can't smuggle the parent's turn back in. Lines with
  no parseable `timestamp` are treated as out-of-window when `:since` is given
  — under-reporting is the safe direction here, double-billing is not.

  `read_steps/2` needs the bound in *both* directions, and takes `:until` as
  well. Tokens are read for the newest run in a chain, where "everything after
  my start" is the right window; steps are backfilled for *every* run in the
  chain, and reading a parent with no upper bound would read past its own
  death and file the child's tool calls under the parent's run id.

  ## Cost — `cost-state` records (bd-be804c)

  The `assistant` lines carry token buckets and no dollar figure, and this
  moduledoc used to stop there ("so a reconciled row records `cost_usd: nil`").
  That was true of `assistant` lines and **false of the file as a whole**: the
  CLI periodically appends its own accounting record,

      {"type":"cost-state","sessionId":"…","totalCostUSD":9.777289,
       "totalAPIDuration":350343,"totalDuration":668525,"startTime":1788556943788,
       "modelUsage":{"claude-opus-5[1m]":{"inputTokens":1048,…,"costUSD":9.777289}},
       "hasUnknownModelCost":false}

  so `read_totals/2` reads `totals.cost_usd` straight off it. **The CLI's number
  is reused verbatim, never recomputed** — it has already applied the
  cache-write/cache-read price split that a local price table would get wrong.

  Three properties of these records drive the arithmetic, all confirmed against
  real files:

    * **No `timestamp` field.** They carry `startTime` (epoch ms, the CLI
      *process* start) instead, which is what `:since` windows them by.
    * **`totalCostUSD` is cumulative within one CLI process, and resets when a
      new process opens the same file** (`--resume`). A real session shows
      `… 47.41 → 6.63 → 121.02 …` — monotone within a `startTime`, restarting
      across one. So the file total is `sum over startTime segments of
      max(totalCostUSD)`: max within a segment absorbs the streaming re-emits
      (consecutive records repeat identical totals), sum across segments keeps a
      resumed process's spend from erasing its parent's.
    * **`modelUsage[model].costUSD`** breaks the same total down per model and is
      summed by the identical rule into `totals.model_costs`.

  A file with no `cost-state` record in window still reconciles tokens, with
  `cost_usd: nil` — graceful degradation, unchanged.

  ## Forked / rolled-over sessions — use `:session_id`

  Every line also carries the `sessionId` it was written under. A session that
  rolls over to a **new** id copies the parent's lines into the new
  `<sid>.jsonl`, and those copies keep the *parent's* `sessionId` — so summing
  the new file whole would bill the parent's spend twice. Pass `:session_id` and
  lines stamped with a *different* id are skipped (lines with no `sessionId` at
  all are kept: they can't be attributed elsewhere). The worker path omits the
  option and is unchanged.
  """

  @typedoc """
  Deduped token totals read off a session JSONL. Every token field is a
  non-negative integer (zero when the session produced no `assistant` usage).
  `model` is the model id seen on the assistant/init lines, or `nil`.
  `skipped_before_since` counts distinct turns excluded by the `:since` cutoff
  (an earlier run's turns in a `--resume`-shared file) — kept for the audit
  trail on the reconciled ledger row.

  `cost_usd` / `model_costs` / `duration_ms` come off the file's `cost-state`
  records (see the moduledoc) and are `nil` / `%{}` / `nil` when none is in
  window — a genuine absence, never a fabricated zero. `cost_state_count` is how
  many such records contributed, for the audit trail.
  """
  @type totals :: %{
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          message_count: non_neg_integer(),
          skipped_before_since: non_neg_integer(),
          model: String.t() | nil,
          cost_usd: float() | nil,
          model_costs: %{optional(String.t()) => float()},
          duration_ms: non_neg_integer() | nil,
          cost_state_count: non_neg_integer()
        }

  @no_cost_note "cost unavailable: reconciled from the on-disk session JSONL, " <>
                  "which recorded no cost-state entry inside this run's window"

  @doc """
  The canonical `cost_note` for a ledger row reconciled from a session JSONL
  that carried no in-window `cost-state` record.

  Shared by `Arbiter.Worker` and `Arbiter.Workers.Reconciler` so a null cost on
  a disk-reconciled row always reads as the same explained limitation. Before
  bd-be804c this said the file "carries no cost figure" at all, which was only
  ever true of its `assistant` lines.
  """
  @spec no_cost_note() :: String.t()
  def no_cost_note, do: @no_cost_note

  @doc """
  Derive Claude Code's project-slug from a worker's cwd: replace every
  character that is not `[A-Za-z0-9]` with `-`. The leading `/` of an absolute
  path becomes the leading `-` this way (no separate prefix step).
  """
  @spec project_slug(String.t()) :: String.t()
  def project_slug(cwd) when is_binary(cwd) do
    String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")
  end

  @doc """
  Locate a session's on-disk JSONL under `config_dir` by its `session_id`.

  Globs `config_dir/projects/*/<session_id>.jsonl`; the session id's UUID
  uniqueness means at most one match. Returns `{:ok, path}` or `:not_found`
  (including when `config_dir` / `session_id` is blank).
  """
  @spec locate(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :not_found
  def locate(config_dir, session_id)
      when is_binary(config_dir) and config_dir != "" and
             is_binary(session_id) and session_id != "" do
    pattern = Path.join([config_dir, "projects", "*", session_id <> ".jsonl"])

    case Path.wildcard(pattern) do
      [path | _] -> {:ok, path}
      [] -> :not_found
    end
  end

  def locate(_config_dir, _session_id), do: :not_found

  @doc """
  Parse a session JSONL at `path` into deduped token totals.

  Streams the file line-by-line, keeps the first `usage` seen per
  `message.id`, and sums the four token buckets. Returns `{:ok, totals}` or
  `{:error, reason}` (e.g. the file is missing). Malformed / non-JSON lines are
  skipped rather than fatal — the file is an append log a crashing process may
  have left with a torn final line.

  ## Options

    * `:since` — a `DateTime` (or ISO8601 string) cutoff. Turns whose line
      `timestamp` is older than it are excluded from the sums. Pass the run's
      start so a `--resume`-shared file doesn't bill this run for the previous
      run's turns (see the moduledoc). Defaults to `nil` (whole file).
      `cost-state` records carry no `timestamp`, so they are windowed by their
      own `startTime` (the CLI process start) instead.
    * `:session_id` — only count lines whose `sessionId` matches. Guards a
      forked / rolled-over file that carries copies of the parent session's
      lines (see the moduledoc). Defaults to `nil` (count every line).

  """
  @spec read_totals(String.t(), keyword()) :: {:ok, totals()} | {:error, term()}
  def read_totals(path, opts \\ []) when is_binary(path) and is_list(opts) do
    since = normalize_since(Keyword.get(opts, :since))
    session_id = Keyword.get(opts, :session_id)

    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, summarize(io, since, session_id)}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convenience: `locate/2` then `read_totals/2`. Returns `{:ok, totals}`,
  `:not_found`, or `{:error, reason}`. `opts` are passed through to
  `read_totals/2` (notably `:since`).
  """
  @spec usage_for(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, totals()} | :not_found | {:error, term()}
  def usage_for(config_dir, session_id, opts \\ []) do
    case locate(config_dir, session_id) do
      {:ok, path} -> read_totals(path, opts)
      :not_found -> :not_found
    end
  end

  @typedoc """
  One reconstructed tool call from a session JSONL: the `tool_use` block's
  name/input paired with its `tool_result` block's error flag and content.
  `occurred_at` / `duration_ms` are nil when the relevant lines carried no
  parseable `timestamp` — an honest gap, not a zero.
  """
  @type step_event :: %{
          tool_use_id: String.t(),
          name: String.t() | nil,
          input: map() | nil,
          output_text: String.t(),
          is_error: boolean(),
          occurred_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc """
  Parse a session JSONL at `path` into the tool calls it records (bd-apwfmy
  Phase 2).

  The same file that answers "how many tokens" also holds every
  `tool_use`/`tool_result` block pair, which makes it the only retroactive
  source of typed steps for runs that finished before live capture shipped.
  Returns `{:ok, steps}` in file order, or `{:error, reason}`.

  Mirrors `read_totals/2`'s parsing discipline:

    * **Keep-first per `tool_use` id**, *not* per `message.id`. The dedupe key
      matters here in a way it does not for tokens: on disk, Claude Code
      writes one line per *content block*, and every block of a turn repeats
      that turn's `message.id` — a `thinking` line, then a `text` line, then
      the `tool_use` line. Keeping only the first line per `message.id` (the
      right rule for `read_totals/2`, where the whole turn is re-emitted)
      therefore throws the tool call away and leaves its result unmatched.
      A `tool_use` id is unique within a session, so keying on it dedupes
      streaming re-emits without discarding split blocks — and keeping the
      *first* sighting is what makes `duration_ms` the real elapsed time
      rather than ~0. Repeated `tool_result`s for an id already resolved are
      likewise ignored.
    * **A `tool_use` with no `tool_result` yields no step.** The session was
      killed mid-call; absent beats a row with invented timing.
    * **Torn/non-JSON lines are skipped**, not fatal.

  ## Options

    * `:since` — a `DateTime` (or ISO8601 string) lower bound, applied to the
      *result* line's timestamp, so a `--resume`-shared file doesn't
      attribute the previous run's tool calls to this one.
    * `:until` — the matching *upper* bound. A `--resume` chain shares one
      file in both directions: reading a parent run without an upper bound
      absorbs every child run's calls that were appended after the parent
      died. Callers pass the run's `completed_at`; a nil one keeps the read
      unbounded above (the run is still open, so there is no later run).

  A step whose result line carries no parseable timestamp is dropped when
  *either* bound is given — the same under-report-rather-than-misattribute
  rule `read_totals/2` uses, since against a bound an undated line is
  ambiguous.

  """
  @spec read_steps(String.t(), keyword()) :: {:ok, [step_event()]} | {:error, term()}
  def read_steps(path, opts \\ []) when is_binary(path) and is_list(opts) do
    window = {
      normalize_bound(Keyword.get(opts, :since)),
      normalize_bound(Keyword.get(opts, :until))
    }

    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, collect_steps(io, window)}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- internals ---------------------------------------------------------

  # Fold the file's lines into {seen_message_ids, totals, cost_segments}.
  # `seen` keeps the first usage per message.id so streaming re-emits don't
  # double count; `cost_segments` keeps the running max per `cost-state`
  # `startTime` (see the moduledoc's cost section) and is folded in at the end.
  defp summarize(io, since, session_id) do
    {_seen, totals, segments} =
      io
      |> IO.stream(:line)
      |> Enum.reduce(
        {MapSet.new(), blank_totals(), %{}},
        &absorb_line(&1, &2, since, session_id)
      )

    apply_cost_segments(totals, segments)
  end

  defp blank_totals do
    %{
      tokens_in: 0,
      tokens_out: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      message_count: 0,
      skipped_before_since: 0,
      model: nil,
      cost_usd: nil,
      model_costs: %{},
      duration_ms: nil,
      cost_state_count: 0
    }
  end

  defp absorb_line(line, acc, since, session_id) do
    case decode(line) do
      {:ok, event} ->
        if own_session?(event, session_id) do
          absorb_event(event, acc, since)
        else
          # A copy of another session's line, carried into this file by a
          # rollover/fork. Counting it here bills its spend a second time.
          acc
        end

      _ ->
        acc
    end
  end

  # No `:session_id` filter, or the line carries no `sessionId` to judge it by
  # (it can't be attributed to any *other* session, so it stays in scope).
  defp own_session?(_event, nil), do: true

  defp own_session?(event, session_id) when is_binary(session_id) do
    case Map.get(event, "sessionId") || Map.get(event, "session_id") do
      nil -> true
      seen when is_binary(seen) -> seen == session_id
      _ -> true
    end
  end

  defp absorb_event(
         %{"type" => "assistant", "message" => %{"id" => id, "usage" => usage} = msg} = event,
         {seen, totals, segments},
         since
       )
       when is_binary(id) and is_map(usage) do
    cond do
      MapSet.member?(seen, id) ->
        # Streaming re-emit of an already-seen turn — skip, but still let a
        # later line backfill the model if we haven't seen one yet.
        {seen, maybe_model(totals, msg), segments}

      not in_window?(event, since) ->
        # A turn from an earlier run sharing this file (`--resume` appends).
        # Mark it seen so a re-emit that straddles the cutoff can't sneak the
        # earlier run's tokens in, but count nothing for it.
        {MapSet.put(seen, id), Map.update!(totals, :skipped_before_since, &(&1 + 1)), segments}

      true ->
        {MapSet.put(seen, id), add_usage(totals, usage, msg), segments}
    end
  end

  defp absorb_event(%{"type" => "cost-state"} = event, {seen, totals, segments}, since) do
    if cost_state_in_window?(event, since) do
      {seen, Map.update!(totals, :cost_state_count, &(&1 + 1)),
       absorb_cost_state(segments, event)}
    else
      {seen, totals, segments}
    end
  end

  defp absorb_event(_event, acc, _since), do: acc

  # No cutoff → everything is in-window. With a cutoff, a line must carry a
  # parseable ISO8601 `timestamp` at or after it; an undated line is treated as
  # out-of-window (under-report rather than risk billing another run's turns).
  defp in_window?(_event, nil), do: true

  defp in_window?(event, %DateTime{} = since) do
    case parse_timestamp(Map.get(event, "timestamp")) do
      {:ok, ts} -> DateTime.compare(ts, since) != :lt
      :error -> false
    end
  end

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_timestamp(_ts), do: :error

  defp normalize_since(value), do: normalize_bound(value)

  defp normalize_bound(nil), do: nil
  defp normalize_bound(%DateTime{} = dt), do: dt

  defp normalize_bound(ts) when is_binary(ts) do
    case parse_timestamp(ts) do
      {:ok, dt} -> dt
      :error -> nil
    end
  end

  defp normalize_bound(_other), do: nil

  defp add_usage(totals, usage, msg) do
    %{
      totals
      | tokens_in: totals.tokens_in + int(usage["input_tokens"]),
        tokens_out: totals.tokens_out + int(usage["output_tokens"]),
        cache_creation_tokens:
          totals.cache_creation_tokens + int(usage["cache_creation_input_tokens"]),
        cache_read_tokens: totals.cache_read_tokens + int(usage["cache_read_input_tokens"]),
        message_count: totals.message_count + 1
    }
    |> maybe_model(msg)
  end

  # `<synthetic>` is Claude Code's placeholder on locally-generated assistant
  # messages (interrupts, error stand-ins) — it names no model, and letting it
  # win the keep-first race stamps it on the ledger row. Observed on a real
  # coordinator session whose $52.77 was filed under `model=<synthetic>`.
  @synthetic_model "<synthetic>"

  defp maybe_model(%{model: nil} = totals, %{"model" => model})
       when is_binary(model) and model != @synthetic_model,
       do: %{totals | model: model}

  defp maybe_model(totals, _msg), do: totals

  # ---- cost-state accounting (bd-be804c) ---------------------------------

  # A `cost-state` record has no `timestamp`; it carries `startTime`, the epoch
  # ms at which *this CLI process* opened the session. That is exactly the right
  # thing to window on: a segment whose process started before the run's own
  # start belongs to an earlier run sharing the file via `--resume`.
  # A record with no usable `startTime` is kept only when no cutoff was given —
  # the same under-report-rather-than-double-bill rule the token path uses.
  defp cost_state_in_window?(_event, nil), do: true

  defp cost_state_in_window?(event, %DateTime{} = since) do
    case segment_started_at(event) do
      %DateTime{} = at -> DateTime.compare(at, since) != :lt
      nil -> false
    end
  end

  defp segment_started_at(event) do
    case Map.get(event, "startTime") do
      ms when is_integer(ms) ->
        case DateTime.from_unix(ms, :millisecond) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Keep the running MAX per segment. Within one CLI process `totalCostUSD`
  # only grows (and repeats verbatim on re-emit); across processes it restarts,
  # which is why segments are summed separately in apply_cost_segments/2.
  defp absorb_cost_state(segments, event) do
    key = Map.get(event, "startTime") || :no_start_time

    seg =
      Map.get(segments, key, %{cost_usd: 0.0, duration_ms: 0, model_costs: %{}})

    Map.put(segments, key, %{
      cost_usd: max(seg.cost_usd, float(Map.get(event, "totalCostUSD"))),
      duration_ms: max(seg.duration_ms, non_neg_int(Map.get(event, "totalDuration"))),
      model_costs: merge_model_costs(seg.model_costs, Map.get(event, "modelUsage"))
    })
  end

  defp merge_model_costs(acc, usage) when is_map(usage) do
    Enum.reduce(usage, acc, fn
      {model, %{"costUSD" => cost}}, acc when is_binary(model) ->
        Map.update(acc, model, float(cost), &max(&1, float(cost)))

      _pair, acc ->
        acc
    end)
  end

  defp merge_model_costs(acc, _usage), do: acc

  # Sum the per-segment maxima into the totals. No in-window `cost-state` at all
  # leaves `cost_usd`/`duration_ms` nil — an honest absence, not a zero.
  defp apply_cost_segments(totals, segments) when map_size(segments) == 0, do: totals

  defp apply_cost_segments(totals, segments) do
    values = Map.values(segments)

    model_costs =
      Enum.reduce(values, %{}, fn seg, acc ->
        Map.merge(acc, seg.model_costs, fn _model, a, b -> a + b end)
      end)

    %{
      totals
      | cost_usd: Enum.reduce(values, 0.0, &(&1.cost_usd + &2)),
        duration_ms: Enum.reduce(values, 0, &(&1.duration_ms + &2)),
        model_costs: model_costs
    }
  end

  defp float(n) when is_float(n), do: n
  defp float(n) when is_integer(n), do: n * 1.0
  defp float(_), do: 0.0

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp decode(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  # ---- step reconstruction (bd-apwfmy Phase 2) ---------------------------

  # Fold the file into {resolved_tool_use_ids, pending_tool_uses, reversed_steps}.
  defp collect_steps(io, window) do
    io
    |> IO.stream(:line)
    |> Enum.reduce({MapSet.new(), %{}, []}, &absorb_step_line(&1, &2, window))
    |> elem(2)
    |> Enum.reverse()
  end

  defp absorb_step_line(line, acc, window) do
    case decode(line) do
      {:ok, event} -> absorb_step_event(event, acc, window)
      _ -> acc
    end
  end

  defp absorb_step_event(
         %{"type" => "assistant", "message" => %{"content" => content}} = event,
         {resolved, pending, steps},
         _window
       )
       when is_list(content) do
    ts = line_timestamp(event)
    {resolved, Enum.reduce(content, pending, &remember_tool_use(&1, &2, ts)), steps}
  end

  defp absorb_step_event(
         %{"type" => "user", "message" => %{"content" => content}} = event,
         acc,
         window
       )
       when is_list(content) do
    ts = line_timestamp(event)
    Enum.reduce(content, acc, &resolve_tool_result(&1, &2, ts, window))
  end

  defp absorb_step_event(_event, acc, _window), do: acc

  # `put_new`: a streaming re-emit repeats the block verbatim, and the FIRST
  # sighting is the one that carries the truthful start time.
  defp remember_tool_use(%{"type" => "tool_use", "id" => id} = block, pending, ts)
       when is_binary(id) do
    Map.put_new(pending, id, %{
      name: Map.get(block, "name"),
      input: Map.get(block, "input"),
      started_at: ts
    })
  end

  defp remember_tool_use(_block, pending, _ts), do: pending

  defp resolve_tool_result(
         %{"type" => "tool_result", "tool_use_id" => id} = block,
         {resolved, pending, steps} = acc,
         ts,
         window
       )
       when is_binary(id) do
    if MapSet.member?(resolved, id) do
      # A repeated result for a call already recorded. One call, one row.
      acc
    else
      resolve_new_tool_result(block, id, {MapSet.put(resolved, id), pending, steps}, ts, window)
    end
  end

  defp resolve_tool_result(_block, acc, _ts, _window), do: acc

  defp resolve_new_tool_result(block, id, {resolved, pending, steps}, ts, window) do
    {call, pending} = Map.pop(pending, id)

    step = %{
      tool_use_id: id,
      name: call && call.name,
      input: call && call.input,
      output_text: tool_result_text(Map.get(block, "content")),
      is_error: !!Map.get(block, "is_error"),
      occurred_at: ts,
      duration_ms: elapsed_ms(call, ts)
    }

    if keep_step?(step, window) do
      {resolved, pending, [step | steps]}
    else
      {resolved, pending, steps}
    end
  end

  defp keep_step?(_step, {nil, nil}), do: true
  # A bound is given but the result line was undated: ambiguous, so dropped.
  defp keep_step?(%{occurred_at: nil}, _window), do: false

  defp keep_step?(%{occurred_at: %DateTime{} = at}, {since, until}) do
    after_since?(at, since) and before_until?(at, until)
  end

  defp after_since?(_at, nil), do: true
  defp after_since?(at, %DateTime{} = since), do: DateTime.compare(at, since) != :lt

  defp before_until?(_at, nil), do: true
  defp before_until?(at, %DateTime{} = until), do: DateTime.compare(at, until) != :gt

  defp elapsed_ms(%{started_at: %DateTime{} = from}, %DateTime{} = to) do
    max(DateTime.diff(to, from, :millisecond), 0)
  end

  defp elapsed_ms(_call, _ts), do: nil

  defp line_timestamp(event) do
    case parse_timestamp(Map.get(event, "timestamp")) do
      {:ok, ts} -> ts
      :error -> nil
    end
  end

  # tool_result content is either a plain string or a list of content blocks.
  defp tool_result_text(text) when is_binary(text), do: text

  defp tool_result_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp tool_result_text(_other), do: ""
end
