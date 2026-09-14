defmodule Arbiter.Sessions.UsageIngest do
  @moduledoc """
  Meter the **coordinator's own** Claude Code sessions into
  `Arbiter.Usage.Event`, by sweeping the session JSONLs the CLI already writes
  to disk (bd-be804c — phase 6 of `docs/browser-hosted-coordinator-sessions.md`,
  §7.4/§7.5).

  ## Why

  `arb usage` has only ever seen spend that belongs to a *task*. The
  coordinator — the interactive Claude Code session that dispatches every
  worker — is roughly a quarter of total consumption and was entirely invisible:
  one measured session went from $9.78 to $325.78 inside a single window
  without moving a single number in any Arbiter report. This module closes that
  hole for **today's CLI coordinator**, with no dependency on the browser
  session lifecycle, transport or UI phases of the RFC.

  It needs no cooperation from the session: no proxy, no `ANTHROPIC_BASE_URL`,
  no OTel collector, nothing that a launch could silently omit. The CLI writes
  the file regardless, in both auth modes and with Remote Control active.

  ## What a row looks like

  One `Usage.Event` per session per ingest cycle that found new spend:

    * `source: :coordinator_session`, `task_id: nil` — this spend belongs to no
      task, which is exactly what that source means. `Arbiter.Usage.summarize/1`
      therefore counts it in `--by source` / `--by day` / `--by provider` and
      keeps it out of `--by task`.
    * `session_id` — the **provider** session id, i.e. the JSONL's basename.
      RFC phase 1 introduces a `sessions` table that adopts this string; until
      then it is the only identity a session has, and it is what
      `arb usage --by session` (phase 7) will group on.
    * `step: :other` — the escape hatch on `Usage.Event`; a coordinator session
      is not work/review/impl.

  ## Idempotency — cumulative minus already-billed

  Re-running must never double-bill, and the files are append logs that grow
  under us. Rather than trying to remember a byte offset or a last-seen
  timestamp, each cycle:

    1. reads the file **whole** into cumulative totals
       (`Arbiter.Usage.ClaudeSessionFile.read_totals/2`, which dedupes streaming
       re-emits by `message.id` and sums `cost-state` per CLI-process segment);
    2. sums what this session has **already** been billed, from the ledger;
    3. writes the difference, and only if some part of it is positive.

  An unchanged file therefore produces a zero delta and no row, a file appended
  between runs produces exactly the appended portion, and a row lost or manually
  deleted simply gets re-derived on the next pass. The ledger is the watermark,
  so there is no side-channel state to corrupt.

  Negative deltas (a truncated or rewritten file) are clamped to zero rather
  than credited — this is a spend ledger, not a balance sheet, and a negative
  usage row would corrupt every rollup that sums it.

  ## Session-id rollover

  `--resume` normally appends to the same `<sid>.jsonl`, which the cumulative
  arithmetic above handles for free. But a session can also roll onto a **new**
  id whose file carries copies of the parent's lines — and those copies keep the
  *parent's* `sessionId`. Summing the new file whole would bill the parent's
  entire history a second time under the child's id, where step 2 above cannot
  see it. So every read passes `session_id:` and `ClaudeSessionFile` skips lines
  stamped with a different session.

  ## Privacy

  This module reads `usage` numbers, `cost-state` numbers, and the session id.
  It **never** persists message content, prompts, tool inputs, tool outputs, or
  anything token-like: `read_totals/2` returns integers, floats, a model name
  and a message count, and `raw` is built from those counts alone — the file's
  text never enters a struct that reaches `Ash.create/2`. Log lines carry paths
  and counts only. `test/arbiter/sessions/usage_ingest_test.exs` proves it with
  a fixture seeded with a prompt, a tool input/output pair and a fake
  `sk-ant-…` string.

  ## Cadence and configuration

  Started in the supervision tree as a periodic sweeper. `ingest/1` is also the
  on-demand entry point — call it directly (from `iex`, a boot task, or a future
  end-of-session hook) and it does the same work synchronously.

      config :arbiter, :coordinator_session_ingest,
        enabled: true,
        interval_ms: 300_000

  Which directories to sweep comes from
  `Arbiter.Config.Paths.coordinator_session_dirs/0`
  (`ARBITER_COORDINATOR_SESSION_DIRS`, or `config :arbiter,
  :coordinator_session_dirs`). It defaults to **empty**, so an install that has
  not opted in ingests nothing and this module is inert.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Config.Paths
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event

  @default_interval_ms 5 * 60_000

  @typedoc "What one `ingest/1` pass did."
  @type report :: %{
          files: non_neg_integer(),
          rows_written: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sweep every configured coordinator session directory once, writing the
  per-session usage delta since the last pass.

  ## Options

    * `:dirs` — directories to sweep, overriding
      `Arbiter.Config.Paths.coordinator_session_dirs/0`. Mainly for tests and
      one-off backfills.

  Returns `{:ok, report}`. Individual file failures are counted in
  `:errors` and logged rather than aborting the sweep — one unreadable JSONL
  must not stop the rest of the fleet's metering.
  """
  @spec ingest(keyword()) :: {:ok, report()}
  def ingest(opts \\ []) when is_list(opts) do
    dirs = Keyword.get_lazy(opts, :dirs, &Paths.coordinator_session_dirs/0)

    report =
      dirs
      |> Enum.flat_map(&session_files/1)
      |> Enum.reduce(%{files: 0, rows_written: 0, errors: 0}, fn path, acc ->
        acc = %{acc | files: acc.files + 1}

        case ingest_file(path) do
          {:ok, :written} -> %{acc | rows_written: acc.rows_written + 1}
          {:ok, :unchanged} -> acc
          {:error, _reason} -> %{acc | errors: acc.errors + 1}
        end
      end)

    {:ok, report}
  end

  # ---- one file ----------------------------------------------------------

  defp session_files(dir) when is_binary(dir) do
    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp session_files(_dir), do: []

  defp ingest_file(path) do
    session_id = Path.basename(path, ".jsonl")

    # `session_id:` is the rollover guard — see the moduledoc. No `:since`: the
    # read is deliberately cumulative and the ledger provides the watermark.
    case ClaudeSessionFile.read_totals(path, session_id: session_id) do
      {:ok, totals} ->
        write_delta(session_id, totals, path)

      {:error, reason} ->
        Logger.warning("Sessions.UsageIngest: cannot read #{path}: #{inspect(reason)}")

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Sessions.UsageIngest: #{path} raised: #{Exception.message(e)}")
      {:error, :raised}
  end

  defp write_delta(session_id, totals, path) do
    billed = already_billed(session_id)

    delta = %{
      tokens_in: clamp(totals.tokens_in - billed.tokens_in),
      tokens_out: clamp(totals.tokens_out - billed.tokens_out),
      cache_creation_tokens: clamp(totals.cache_creation_tokens - billed.cache_creation_tokens),
      cache_read_tokens: clamp(totals.cache_read_tokens - billed.cache_read_tokens),
      message_count: clamp(totals.message_count - billed.message_count),
      cost_usd: cost_delta(totals.cost_usd, billed.cost_usd),
      duration_ms: clamp((totals.duration_ms || 0) - billed.duration_ms)
    }

    if new_spend?(delta) do
      insert_row(session_id, totals, delta, path)
    else
      {:ok, :unchanged}
    end
  end

  # Everything this session has already been charged for. Summing the rows is
  # what makes a re-run a no-op; `occurred_at` plays no part, so a clock jump
  # can't double-bill.
  defp already_billed(session_id) do
    Event
    |> Ash.Query.filter(session_id == ^session_id and source == :coordinator_session)
    |> Ash.read!()
    |> Enum.reduce(
      %{
        tokens_in: 0,
        tokens_out: 0,
        cache_creation_tokens: 0,
        cache_read_tokens: 0,
        message_count: 0,
        cost_usd: 0.0,
        duration_ms: 0
      },
      fn ev, acc ->
        %{
          acc
          | tokens_in: acc.tokens_in + int(ev.tokens_in),
            tokens_out: acc.tokens_out + int(ev.tokens_out),
            cache_creation_tokens: acc.cache_creation_tokens + int(ev.cache_creation_tokens),
            cache_read_tokens: acc.cache_read_tokens + int(ev.cache_read_tokens),
            message_count: acc.message_count + billed_message_count(ev),
            cost_usd: acc.cost_usd + flt(ev.cost_usd),
            duration_ms: acc.duration_ms + int(ev.duration_ms)
        }
      end
    )
  end

  # The message count lives in `raw`, the one place an ingest row records its
  # own provenance. A row written by some other path (or an older schema) has
  # none; treating that as 0 can only ever under-suppress, never double-bill,
  # because the token deltas are the real gate.
  defp billed_message_count(%Event{raw: %{"arb_usage_source" => %{"message_count" => n}}})
       when is_integer(n),
       do: n

  defp billed_message_count(_ev), do: 0

  # A file with no `cost-state` at all reports nil, which is an absence, not a
  # zero — keep it nil so the row records the same honest gap the worker path
  # does rather than claiming this session was free.
  defp cost_delta(nil, _billed), do: nil
  defp cost_delta(total, billed), do: max(total - billed, 0.0)

  # A cost-only delta counts: `cost-state` records land between turns, so an
  # otherwise-quiet cycle can still carry real dollars.
  defp new_spend?(delta) do
    delta.tokens_in > 0 or delta.tokens_out > 0 or delta.cache_creation_tokens > 0 or
      delta.cache_read_tokens > 0 or delta.message_count > 0 or (delta.cost_usd || 0.0) > 0.0
  end

  defp insert_row(session_id, totals, delta, path) do
    attrs = %{
      source: :coordinator_session,
      # Not a missing value: coordinator spend belongs to no task. See
      # `Arbiter.Usage.Event`'s source table.
      task_id: nil,
      session_id: session_id,
      step: :other,
      provider: "claude",
      model: totals.model,
      tokens_in: delta.tokens_in,
      tokens_out: delta.tokens_out,
      cache_creation_tokens: delta.cache_creation_tokens,
      cache_read_tokens: delta.cache_read_tokens,
      cost_usd: delta.cost_usd,
      cost_note: if(is_nil(delta.cost_usd), do: ClaudeSessionFile.no_cost_note()),
      duration_ms: nonzero(delta.duration_ms),
      occurred_at: DateTime.utc_now(),
      # Counts and provenance only — never a byte of the transcript. See the
      # moduledoc's privacy section.
      raw: %{
        "arb_usage_source" => %{
          "reconciled_from" => "session_jsonl",
          "via" => "coordinator_session_ingest",
          "message_count" => delta.message_count,
          "cumulative_message_count" => totals.message_count,
          "cost_state_count" => totals.cost_state_count
        }
      }
    }

    case Ash.create(Event, attrs) do
      {:ok, _ev} ->
        Logger.info(
          "Sessions.UsageIngest: session=#{session_id} +#{delta.message_count} msgs " <>
            "+#{delta.tokens_in}/#{delta.tokens_out} tokens cost=#{inspect(delta.cost_usd)}"
        )

        {:ok, :written}

      {:error, reason} ->
        Logger.warning(
          "Sessions.UsageIngest: failed to write row for #{path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp clamp(n) when is_integer(n), do: max(n, 0)
  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0
  defp flt(n) when is_number(n), do: n * 1.0
  defp flt(_), do: 0.0
  defp nonzero(0), do: nil
  defp nonzero(n), do: n

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:ingest, state) do
    ingest()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :ingest, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    :arbiter
    |> Application.get_env(:coordinator_session_ingest, [])
    |> Keyword.get(key, default)
  end
end
