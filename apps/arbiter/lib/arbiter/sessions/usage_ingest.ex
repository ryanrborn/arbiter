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

  One `Usage.Event` per session **per UTC day** per ingest cycle that found new
  spend on that day:

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

  ## Dating — the transcript, never the clock

  A coordinator session is not an event, it is a *month*: the live one has been
  appending since 2026-09-04. Dating its rows at ingest time (as the first
  deploy of this module did) files weeks of spend on whichever day the sweeper
  happened to run, and `arb usage --by day` / `--since 1d` read exactly that
  column. So every row is dated from the session's own turn timestamps:
  `ClaudeSessionFile` splits the file into UTC-day buckets, each carrying its
  own token counts, its share of the file's cost, and the newest turn
  timestamp in that day — which becomes the row's `occurred_at`. A delta that
  spans midnight writes two rows, not one.

  ## Idempotency — cumulative minus already-billed, per day

  Re-running must never double-bill, and the files are append logs that grow
  under us. Rather than trying to remember a byte offset or a last-seen
  timestamp, each cycle:

    1. reads the file **whole** into cumulative totals
       (`Arbiter.Usage.ClaudeSessionFile.read_totals/2`, which dedupes streaming
       re-emits by `message.id`, sums `cost-state` per CLI-process segment, and
       buckets the turns by UTC day);
    2. sums what this session has **already** been billed **on each day**, from
       the ledger;
    3. writes the per-day difference, and only where some part of it is
       positive.

  An unchanged file therefore produces zero deltas and no rows, a file appended
  between runs produces exactly the appended portion charged to the day it
  happened on, and a row lost or manually deleted simply gets re-derived on the
  next pass. The ledger is the watermark, so there is no side-channel state to
  corrupt. (That is also why the rows written by the mis-dating first deploy
  could simply be deleted — see
  `priv/repo/migrations/20260914060000_redate_coordinator_session_usage.exs`.)

  Negative deltas (a truncated or rewritten file) are clamped to zero rather
  than credited — this is a spend ledger, not a balance sheet, and a negative
  usage row would corrupt every rollup that sums it.

  ## Cost

  `cost_usd` is the CLI's own `cost-state` figure whenever the file has one,
  apportioned across the day buckets. Claude Code **2.1.270 writes none at
  all**, so those files fall back to `Arbiter.Usage.ClaudePricing` — the token
  buckets at published list prices — and the row's `cost_note` says so. A model
  that isn't in the price table still yields an explained null rather than a
  guess.

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

  ## Browser-hosted sessions (bd-9mrzti)

  A browser-hosted `Arbiter.Sessions.Session` writes its transcript under its
  own `config_dir` (`<config_dir>/projects/<slug>/<provider_session_id>.jsonl`
  — see `Sessions.Stream`'s discovery of the CLI's own project-slug
  directory), not under `coordinator_session_dirs`, which only ever pointed at
  the CLI coordinator's own config dir. Every non-ended `Arbiter.Sessions.list/0`
  row is therefore swept too, on the same cadence, into the same
  `:coordinator_session` rows — so `arb usage --by session` and the `/sessions`
  list column (`ArbiterWeb.SessionIndexLive`) both read one ledger regardless
  of which kind of session produced the spend. `Sessions.mark_ended/2` also
  triggers one final single-session sweep synchronously (`dirs: [],
  sessions: [ended]`) so a session's last few turns land before the next
  periodic pass — otherwise up to `interval_ms` of real spend could sit
  unswept on a row nothing will read again.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Resolver
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
    * `:sessions` — `Arbiter.Sessions.Session` structs to sweep (their
      `config_dir`'s `projects/*/*.jsonl`), overriding `Arbiter.Sessions.list/0`
      filtered to non-ended. Passing this explicitly (as `mark_ended/2` does,
      with a single already-ended session) skips that status filter — the
      caller has already decided which sessions it wants read.

  Returns `{:ok, report}`. Individual file failures are counted in
  `:errors` and logged rather than aborting the sweep — one unreadable JSONL
  must not stop the rest of the fleet's metering.
  """
  @spec ingest(keyword()) :: {:ok, report()}
  def ingest(opts \\ []) when is_list(opts) do
    dirs = Keyword.get_lazy(opts, :dirs, &Paths.coordinator_session_dirs/0)

    sessions =
      Keyword.get_lazy(opts, :sessions, fn ->
        Enum.reject(Arbiter.Sessions.list(), &(&1.status == :ended))
      end)

    files_with_ws =
      (Enum.flat_map(dirs, &session_files_with_ws/1) ++
         Enum.flat_map(sessions, &browser_session_files_with_ws/1))
      |> Enum.uniq_by(&elem(&1, 0))

    report =
      files_with_ws
      |> Enum.reduce(%{files: 0, rows_written: 0, errors: 0}, fn {path, workspace_id}, acc ->
        %{rows: rows, errors: errors} = ingest_file(path, workspace_id)

        %{
          acc
          | files: acc.files + 1,
            rows_written: acc.rows_written + rows,
            errors: acc.errors + errors
        }
      end)

    {:ok, report}
  end

  # ---- one file ----------------------------------------------------------

  defp session_files_with_ws(dir) when is_binary(dir) do
    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{&1, nil})
  end

  defp session_files_with_ws(_dir), do: []

  # A browser-hosted session's transcript lives two levels deeper than a
  # coordinator dir — `<config_dir>/projects/<slug>/<sid>.jsonl` — because the
  # CLI names the middle directory after the project path, not the session.
  defp browser_session_files_with_ws(%{config_dir: config_dir} = session)
       when is_binary(config_dir) and config_dir != "" do
    workspace_id = Map.get(session, :workspace_id)

    [config_dir, "projects", "*", "*.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{&1, workspace_id})
  end

  defp browser_session_files_with_ws(_session), do: []

  defp ingest_file(path, workspace_id) do
    session_id = Path.basename(path, ".jsonl")

    # `session_id:` is the rollover guard — see the moduledoc. No `:since`: the
    # read is deliberately cumulative and the ledger provides the watermark.
    case ClaudeSessionFile.read_totals(path, session_id: session_id) do
      {:ok, totals} ->
        write_deltas(session_id, totals, path, workspace_id)

      {:error, reason} ->
        Logger.warning("Sessions.UsageIngest: cannot read #{path}: #{inspect(reason)}")

        %{rows: 0, errors: 1}
    end
  rescue
    e ->
      Logger.warning("Sessions.UsageIngest: #{path} raised: #{Exception.message(e)}")
      %{rows: 0, errors: 1}
  end

  # One row per (session, UTC day) that gained spend since the last pass. The
  # day comes from the transcript's own timestamps, never from the clock — see
  # the moduledoc's dating section.
  defp write_deltas(session_id, totals, path, workspace_id) do
    billed = already_billed_by_day(session_id)
    note = ClaudeSessionFile.cost_note_for(totals)
    ctx = %{session_id: session_id, path: path, workspace_id: workspace_id}

    totals
    |> day_buckets()
    |> Enum.sort_by(fn {day, _bucket} -> day end, Date)
    |> Enum.reduce(%{rows: 0, errors: 0}, fn {day, bucket}, acc ->
      already = billed_for(totals, billed, day)
      delta = delta_for(bucket, already)

      cond do
        not new_spend?(delta) ->
          acc

        match?(
          {:ok, _},
          insert_row(ctx, totals, day, bucket, delta, already, note)
        ) ->
          %{acc | rows: acc.rows + 1}

        true ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # A *dated* bucket is its own watermark: the ledger rows filed under that day
  # are exactly what it has been billed for, which is what lets an append to
  # today leave last week's rows alone. An *undated* bucket is a different
  # animal — `day_buckets/1` keys the whole file's cumulative totals on today,
  # so today's ledger stops being the right comparand the moment the UTC day
  # rolls over and the slate looks empty again. Compare that one against the
  # whole session's ledger instead.
  defp billed_for(%{by_day: by_day}, billed, day) when map_size(by_day) > 0,
    do: Map.get(billed, day, blank_billed())

  defp billed_for(_totals, billed, _day),
    do: billed |> Map.values() |> Enum.reduce(blank_billed(), &merge_billed/2)

  defp merge_billed(a, acc) do
    %{
      acc
      | tokens_in: acc.tokens_in + a.tokens_in,
        tokens_out: acc.tokens_out + a.tokens_out,
        cache_creation_tokens: acc.cache_creation_tokens + a.cache_creation_tokens,
        cache_read_tokens: acc.cache_read_tokens + a.cache_read_tokens,
        message_count: acc.message_count + a.message_count,
        cost_usd: acc.cost_usd + a.cost_usd,
        duration_ms: acc.duration_ms + a.duration_ms
    }
  end

  # `by_day` is empty only for a file whose turns carry no parseable timestamp
  # at all. Rather than drop that spend, date it now and say so on the row —
  # the same under-report-never-double-bill instinct applies, and the ledger
  # arithmetic below is per-day either way.
  defp day_buckets(%{by_day: by_day}) when map_size(by_day) > 0, do: by_day

  defp day_buckets(totals) do
    now = DateTime.utc_now()

    %{
      DateTime.to_date(now) => %{
        tokens_in: totals.tokens_in,
        tokens_out: totals.tokens_out,
        cache_creation_tokens: totals.cache_creation_tokens,
        cache_read_tokens: totals.cache_read_tokens,
        message_count: totals.message_count,
        cost_usd: totals.cost_usd,
        last_at: now
      }
    }
  end

  defp delta_for(bucket, billed) do
    %{
      tokens_in: clamp(bucket.tokens_in - billed.tokens_in),
      tokens_out: clamp(bucket.tokens_out - billed.tokens_out),
      cache_creation_tokens: clamp(bucket.cache_creation_tokens - billed.cache_creation_tokens),
      cache_read_tokens: clamp(bucket.cache_read_tokens - billed.cache_read_tokens),
      message_count: clamp(bucket.message_count - billed.message_count),
      cost_usd: cost_delta(bucket.cost_usd, billed.cost_usd)
    }
  end

  # Everything this session has already been charged for, split by the UTC day
  # the row was filed under. Summing the ledger is what makes a re-run a no-op;
  # doing it per day is what lets a *dated* row be the watermark for its own
  # day without an append to today re-billing last week.
  defp already_billed_by_day(session_id) do
    Event
    |> Ash.Query.filter(session_id == ^session_id and source == :coordinator_session)
    |> Ash.read!()
    |> Enum.group_by(&row_day/1)
    |> Map.new(fn {day, evs} -> {day, Enum.reduce(evs, blank_billed(), &add_billed/2)} end)
  end

  defp row_day(%Event{occurred_at: %DateTime{} = at}), do: DateTime.to_date(at)
  defp row_day(%Event{inserted_at: %DateTime{} = at}), do: DateTime.to_date(at)
  defp row_day(_ev), do: Date.utc_today()

  defp blank_billed do
    %{
      tokens_in: 0,
      tokens_out: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      message_count: 0,
      cost_usd: 0.0,
      duration_ms: 0
    }
  end

  defp add_billed(ev, acc) do
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

  # The message count lives in `raw`, the one place an ingest row records its
  # own provenance. A row written by some other path (or an older schema) has
  # none; treating that as 0 can only ever under-suppress, never double-bill,
  # because the token deltas are the real gate.
  defp billed_message_count(%Event{raw: %{"arb_usage_source" => %{"message_count" => n}}})
       when is_integer(n),
       do: n

  defp billed_message_count(_ev), do: 0

  # A day with no cost at all reports nil, which is an absence, not a zero —
  # keep it nil so the row records the same honest gap the worker path does
  # rather than claiming this session was free.
  defp cost_delta(nil, _billed), do: nil
  defp cost_delta(total, billed), do: max(total - billed, 0.0)

  # A cost-only delta counts: a `cost-state` record can land between turns, so
  # an otherwise-quiet cycle can still carry real dollars.
  defp new_spend?(delta) do
    delta.tokens_in > 0 or delta.tokens_out > 0 or delta.cache_creation_tokens > 0 or
      delta.cache_read_tokens > 0 or delta.message_count > 0 or (delta.cost_usd || 0.0) > 0.0
  end

  defp insert_row(ctx, totals, day, bucket, delta, billed, note) do
    %{session_id: session_id, path: path, workspace_id: workspace_id} = ctx
    account_id = resolve_account_id(workspace_id)

    attrs = %{
      source: :coordinator_session,
      # Not a missing value: coordinator spend belongs to no task. See
      # `Arbiter.Usage.Event`'s source table.
      task_id: nil,
      session_id: session_id,
      step: :other,
      provider: "claude",
      workspace_id: workspace_id,
      provider_account_id: account_id,
      provider_credential_id: Resolver.credential_id(account_id),
      model: totals.model,
      tokens_in: delta.tokens_in,
      tokens_out: delta.tokens_out,
      cache_creation_tokens: delta.cache_creation_tokens,
      cache_read_tokens: delta.cache_read_tokens,
      cost_usd: delta.cost_usd,
      cost_note: note,
      duration_ms: duration_delta(totals, bucket, billed),
      # The newest turn in this day, so `--by day` and `--since` see the spend
      # where it actually happened rather than where the sweeper found it.
      occurred_at: bucket.last_at,
      # Counts and provenance only — never a byte of the transcript. See the
      # moduledoc's privacy section.
      raw: %{
        "arb_usage_source" => %{
          "reconciled_from" => "session_jsonl",
          "via" => "coordinator_session_ingest",
          "message_count" => delta.message_count,
          "day" => Date.to_iso8601(day),
          "day_message_count" => bucket.message_count,
          "cumulative_message_count" => totals.message_count,
          "cost_state_count" => totals.cost_state_count,
          "cost_source" => to_string(totals.cost_source || "none")
        }
      }
    }

    case Ash.create(Event, attrs) do
      {:ok, ev} ->
        Logger.info(
          "Sessions.UsageIngest: session=#{session_id} day=#{Date.to_iso8601(day)} " <>
            "+#{delta.message_count} msgs +#{delta.tokens_in}/#{delta.tokens_out} tokens " <>
            "cost=#{inspect(delta.cost_usd)}"
        )

        {:ok, ev}

      {:error, reason} ->
        Logger.warning(
          "Sessions.UsageIngest: failed to write row for #{path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp resolve_account_id(workspace_id) do
    case Resolver.account_id(workspace_id, "claude") do
      id when is_binary(id) -> id
      nil -> Resolver.account_id_for_probe("claude")
    end
  end

  # Duration is cumulative on disk, so it needs the same watermark treatment as
  # tokens: write only what this day has gained since the last pass. Without it
  # every sweep re-bills the whole day and `Usage.summarize/1` — which sums the
  # column into every rollup — inflates monotonically.
  defp duration_delta(totals, bucket, billed) do
    case day_duration_ms(totals, bucket) do
      nil -> nil
      ms -> nonzero(clamp(ms - billed.duration_ms))
    end
  end

  # `cost-state` reports one duration for the whole file; apportion it by this
  # day's share of the turns so the per-day rows don't each claim the lot.
  defp day_duration_ms(%{duration_ms: nil}, _bucket), do: nil
  defp day_duration_ms(%{message_count: 0}, _bucket), do: nil

  defp day_duration_ms(totals, bucket) do
    nonzero(round(totals.duration_ms * bucket.message_count / totals.message_count))
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
