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

  ## Cost

  The on-disk `assistant` lines carry token buckets but **no per-turn dollar
  figure** (that lives only in the `result` event this fallback exists precisely
  because we're missing). So a reconciled row records deduped token counts with
  `cost_usd` left `nil` — graceful degradation, tokens are the ask. Computing a
  dollar cost from a price table is intentionally out of scope here.
  """

  @typedoc """
  Deduped token totals read off a session JSONL. Every token field is a
  non-negative integer (zero when the session produced no `assistant` usage).
  `model` is the model id seen on the assistant/init lines, or `nil`.
  `skipped_before_since` counts distinct turns excluded by the `:since` cutoff
  (an earlier run's turns in a `--resume`-shared file) — kept for the audit
  trail on the reconciled ledger row.
  """
  @type totals :: %{
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          message_count: non_neg_integer(),
          skipped_before_since: non_neg_integer(),
          model: String.t() | nil
        }

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

  """
  @spec read_totals(String.t(), keyword()) :: {:ok, totals()} | {:error, term()}
  def read_totals(path, opts \\ []) when is_binary(path) and is_list(opts) do
    since = normalize_since(Keyword.get(opts, :since))

    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, summarize(io, since)}
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

  # Fold the file's lines into {seen_message_ids, totals}. `seen` keeps the
  # first usage per message.id so streaming re-emits don't double count.
  defp summarize(io, since) do
    io
    |> IO.stream(:line)
    |> Enum.reduce({MapSet.new(), blank_totals()}, &absorb_line(&1, &2, since))
    |> elem(1)
  end

  defp blank_totals do
    %{
      tokens_in: 0,
      tokens_out: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      message_count: 0,
      skipped_before_since: 0,
      model: nil
    }
  end

  defp absorb_line(line, {seen, totals} = acc, since) do
    case decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"id" => id, "usage" => usage} = msg} = event}
      when is_binary(id) and is_map(usage) ->
        cond do
          MapSet.member?(seen, id) ->
            # Streaming re-emit of an already-seen turn — skip, but still let a
            # later line backfill the model if we haven't seen one yet.
            {seen, maybe_model(totals, msg)}

          not in_window?(event, since) ->
            # A turn from an earlier run sharing this file (`--resume` appends).
            # Mark it seen so a re-emit that straddles the cutoff can't sneak the
            # earlier run's tokens in, but count nothing for it.
            {MapSet.put(seen, id), Map.update!(totals, :skipped_before_since, &(&1 + 1))}

          true ->
            {MapSet.put(seen, id), add_usage(totals, usage, msg)}
        end

      _ ->
        acc
    end
  end

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

  defp maybe_model(%{model: nil} = totals, %{"model" => model}) when is_binary(model),
    do: %{totals | model: model}

  defp maybe_model(totals, _msg), do: totals

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
