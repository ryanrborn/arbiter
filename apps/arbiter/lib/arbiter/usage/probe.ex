defmodule Arbiter.Usage.Probe do
  @moduledoc """
  Ledger capture for Arbiter's one-shot agent-CLI round-trips (bd-adyhvn).

  Two callers spend real plan quota without ever going through
  `Arbiter.Worker` — which is the only path that writes `usage_events`:

    * `Arbiter.Quota.RefreshProbe` — one `claude --print "ok"` per workspace
      whenever the quota snapshot needs refreshing (~57K cache-read tokens a
      call, because a one-token prompt still ships the CLI's system prompt and
      tool definitions);
    * `Arbiter.Agents.Preflight` — one `claude --print "ping"` per dispatch
      **and** per resume, plus the `CredentialWatchdog`'s periodic check.

  ## Capture path: the CLI's own `--output-format json`, not the proxy

  Both probes now ask the CLI for `--output-format json` and read the `usage`
  object out of their own stdout. The alternative — teaching
  `ArbiterWeb.AnthropicProxyController` to parse response bodies — is more
  general (it would cover any provider traffic through the proxy) but means
  buffering and parsing a **streaming hot path** that every real worker's
  traffic flows through, to recover numbers the CLI hands us for free at the
  one place we already own the port. The proxy stays a pass-through.

  ## Why not read the CLI's own session JSONL

  A third option was proposed and preferred on the ticket: read the session
  JSONL the CLI writes at `<config_dir>/projects/<slug>/<session-id>.jsonl`,
  which `Arbiter.Usage.ClaudeSessionFile` already locates and parses. It is the
  right answer for a **PTY/coordinator session** (bd-cyxzvq), where stdout is a
  rendered TUI and the result object does not exist, and it is mechanically
  reachable here too — `claude --session-id <uuid>` lets the caller name the
  file in advance, so no glob race.

  It is the wrong answer for *these two* callers, for one reason: **the JSONL
  carries no cost figure.** `Arbiter.Worker` already says so where it
  reconciles from disk (`@disk_reconciled_cost_note`, `worker.ex:218`), and
  `ClaudeSessionFile.read_totals/2` accordingly returns tokens only. The
  per-session `cost-state` record that does carry `totalCostUSD` is emitted
  periodically during long sessions; a one-shot `--print` round-trip is over
  before one is written. Since the whole point of this ticket is that ~$3/day
  and ~$2/day of *spend* were invisible, and this repo has no Claude price
  table to derive dollars from tokens (only `Arbiter.Agents.Gemini.Pricing`),
  a JSONL-only probe would have recorded tokens and a "cost unavailable" note
  — replacing an invisible number with an unpriced one.

  The `result` object gives tokens **and** `total_cost_usd`, priced by the CLI
  itself. So: result object for one-shot probes, session JSONL for sessions.

  ## Why the result object is stripped from the classifier's view

  `Arbiter.Worker.StopReason.classify/2` matches provider-error signatures by
  substring over the probe's output — including bare `\\b401\\b` and `\\b402\\b`.
  The CLI's structured success payload is full of integers: a probe that
  happened to report `"input_tokens":401` would be classified `:auth_expired`
  and, on the pre-flight path, would refuse the dispatch. So `parse/1` returns
  the output lines **with the success payload removed**; only genuine
  diagnostic output reaches the classifier. An `is_error: true` payload is
  deliberately left in place — that one *is* the diagnostic.

  ## Coordinator / terminal sessions (bd-cyxzvq)

  A browser-hosted coordinator session or an interactive terminal session has
  no task either, and needs no further migration: write a row with
  `source: :coordinator_session` / `:terminal_session`, `task_id: nil`, and the
  CLI's `session_id` — `session_id` has always been nullable and is the natural
  key for a session's (possibly many) rows. `record/3` already accepts exactly
  that shape.
  """

  require Logger

  alias Arbiter.Usage.Event

  @type usage :: %{
          optional(:tokens_in) => integer() | nil,
          optional(:tokens_out) => integer() | nil,
          optional(:cache_creation_tokens) => integer() | nil,
          optional(:cache_read_tokens) => integer() | nil,
          optional(:cost_usd) => float() | nil,
          optional(:duration_ms) => integer() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:raw) => map()
        }

  @no_usage_note "no structured usage in probe output (CLI returned no `--output-format json` result object)"

  @doc """
  Split a probe's captured output into `{usage_or_nil, lines_for_the_classifier}`.

  `lines` is oldest-first, exactly as `Arbiter.Agents.Preflight` and
  `Arbiter.Quota.RefreshProbe` collect it. When one of them is the CLI's
  successful `result` object, its token counts are extracted and that line is
  removed from the returned list (see the moduledoc). Anything else passes
  through untouched.
  """
  @spec parse([String.t()]) :: {usage() | nil, [String.t()]}
  def parse(lines) when is_list(lines) do
    Enum.reduce(lines, {nil, []}, fn line, {usage, kept} ->
      case decode_result(line) do
        {:ok, event} ->
          # A success payload is structured data, not diagnostics — extract and
          # drop it. An error payload stays visible to the classifier.
          {from_result(event), kept}

        :error ->
          {usage, [line | kept]}
      end
    end)
    |> then(fn {usage, kept} -> {usage, Enum.reverse(kept)} end)
  end

  @doc """
  Insert one `usage_events` row for a probe round-trip. Best-effort: a ledger
  hiccup never fails the probe (the caller's verdict — quota refreshed, auth
  ok — does not depend on it).

  `source` is one of `Arbiter.Usage.Event.sources/0` (in practice `:probe` or
  `:preflight`). `usage` is `parse/1`'s first element, or `nil` when the CLI
  returned nothing structured — in which case the row is still written, with a
  `cost_note` explaining the absence, so the *attempt* is visible rather than
  the spend silently vanishing.

  Options: `:workspace_id`, `:task_id`, `:provider`, `:exit_status`,
  `:duration_ms` (fallback when the payload carried none), `:model`,
  `:session_id`, `:repo`.
  """
  @spec record(atom(), usage() | nil, keyword()) :: :ok | :error
  def record(source, usage, opts \\ []) when is_atom(source) and is_list(opts) do
    usage = usage || %{}

    attrs = %{
      task_id: Keyword.get(opts, :task_id),
      source: source,
      workspace_id: Keyword.get(opts, :workspace_id),
      repo: Keyword.get(opts, :repo),
      # Probes are not authoring/reviewing/implementing work — `:other` is the
      # step enum's existing escape hatch for exactly this.
      step: :other,
      model: Map.get(usage, :model) || Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider),
      tokens_in: Map.get(usage, :tokens_in),
      tokens_out: Map.get(usage, :tokens_out),
      cache_creation_tokens: Map.get(usage, :cache_creation_tokens),
      cache_read_tokens: Map.get(usage, :cache_read_tokens),
      cost_usd: Map.get(usage, :cost_usd),
      cost_note: cost_note(usage),
      duration_ms: Map.get(usage, :duration_ms) || Keyword.get(opts, :duration_ms),
      exit_status: Keyword.get(opts, :exit_status),
      session_id: Map.get(usage, :session_id) || Keyword.get(opts, :session_id),
      occurred_at: DateTime.utc_now(),
      raw: Map.get(usage, :raw)
    }

    case Ash.create(Event, attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.debug("Usage.Probe.record/3 swallowed (#{source}): #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.debug("Usage.Probe.record/3 raised (#{source}): #{Exception.message(e)}")
      :error
  end

  # ---- internals ---------------------------------------------------------

  defp cost_note(usage) do
    if Map.get(usage, :cost_usd), do: nil, else: @no_usage_note
  end

  # A line is a probe result payload only when it decodes to a JSON object
  # tagged `"type": "result"` that is NOT an error. Everything else — plain
  # text, a JSON array, an `is_error: true` result — is diagnostic output and
  # must survive into the classifier's haystack.
  defp decode_result(line) when is_binary(line) do
    trimmed = String.trim(line)

    with true <- String.starts_with?(trimmed, "{"),
         {:ok, %{"type" => "result"} = event} <- Jason.decode(trimmed),
         false <- truthy?(event["is_error"]) do
      {:ok, event}
    else
      _ -> :error
    end
  end

  defp decode_result(_), do: :error

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp from_result(%{} = event) do
    usage = event["usage"] || %{}

    %{
      tokens_in: number(usage["input_tokens"]),
      tokens_out: number(usage["output_tokens"]),
      cache_creation_tokens: number(usage["cache_creation_input_tokens"]),
      cache_read_tokens: number(usage["cache_read_input_tokens"]),
      cost_usd: float(event["total_cost_usd"]),
      duration_ms: number(event["duration_ms"]),
      session_id: string(event["session_id"]),
      model: string(event["model"]),
      raw: event
    }
  end

  defp number(n) when is_integer(n), do: n
  defp number(n) when is_float(n), do: trunc(n)
  defp number(_), do: nil

  defp float(n) when is_float(n), do: n
  defp float(n) when is_integer(n), do: n / 1
  defp float(_), do: nil

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_), do: nil
end
