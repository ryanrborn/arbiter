defmodule Arbiter.Usage.CodexUsageBackfill do
  @moduledoc """
  Backfill `usage_events` rows for codex probes that landed with
  `tokens_in`/`tokens_out: nil` before bd-96mn8i taught `Arbiter.Usage.Probe`
  codex's `turn.completed` wire shape.

  Every one of those rows was written by a probe process whose stdout the CLI
  itself never stops writing to disk: `~/.codex/sessions/…/rollout-*.jsonl`
  carries the same `token_count` totals the fixed live parser now reads
  in-band. This module locates the matching rollout for each affected row
  (`Arbiter.Usage.CodexSessionFile.find_for_probe/3`) and writes the recovered
  totals back onto it, so the historical rows read the same as a fixed live
  probe rather than staying a silent gap next to it.

  ## Properties this has to hold

    * **Dry by default.** `backfill/1` reports what it *would* write unless
      passed `apply?: true`, matching `Arbiter.Workers.StepBackfill` and
      `mix arbiter.backfill_run_steps`.
    * **Only touches rows this fix actually caused.** The query is
      `provider == "codex" and source == :preflight and is_nil(tokens_in)` —
      the bug this backfill recovers from was in `Arbiter.Usage.Probe`
      (`source: :preflight`), never in the `source: :task` worker path
      (`Arbiter.Worker`'s `absorb_usage/2`), which already wrote its own
      honest note (round 5 finding 1). A `source: :task` row is left alone
      entirely — its token columns and its worker-written `cost_note` are
      never touched by this module — and a row that already carries tokens
      (including a literal `0` some other cause wrote) is never overwritten
      either.
    * **Honest gaps.** A row whose rollout has been reaped, or whose rollout
      carries no `token_count` line at all (a probe that failed before the
      CLI ever reported usage), is *counted*, not silently skipped — see
      `report/0`'s shape. Those rows keep `tokens_in: nil` (already the
      correct "unknown" representation — `Arbiter.Usage.Probe.record/3`
      writes nil, never zero, for a row with no usage payload), but under
      `apply?: true` also get their `cost_note` rewritten from the pre-fix
      `Probe.@no_usage_note` (which blames the CLI for reporting nothing —
      disproven by this backfill's own existence) to `@no_rollout_note` /
      `@no_token_count_note`, so every codex row converges on a note that is
      actually true.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Usage.CodexSessionFile
  alias Arbiter.Usage.Event

  @backfill_note "backfilled from on-disk codex rollout JSONL (bd-96mn8i round 2): " <>
                   "Probe.parse/1 didn't recognize codex's turn.completed shape until this fix, " <>
                   "so the live probe wrote no tokens; recovered from the CLI's own session file. " <>
                   "Cost stays unavailable — codex plan usage is metered against the ChatGPT " <>
                   "subscription, not billed per call."

  # bd-96mn8i round 5 finding 2: the two skip branches below used to leave
  # the pre-fix `Probe.@no_usage_note` in place — a note that blames the CLI
  # for reporting no result object, which this backfill's own existence
  # disproves (the CLI DID report one; the live parser just didn't
  # recognize it before this fix). Give each skip branch a note that says
  # what's actually true instead, so every codex row converges on an honest
  # cause rather than 1,182 of them keeping a disproven one forever.
  #
  # bd-96mn8i round 9 finding 1: that "the parser dropped it" story is only
  # true for a row whose probe actually completed (`exit_status == 0`) and
  # therefore printed a result object for the pre-fix parser to fail to
  # parse. A probe that exited non-zero, or timed out (`exit_status` nil —
  # see `Preflight.check/2`'s `:timeout` path), never reported a result
  # object at all: there was nothing for the parser to drop. Against the
  # live ledger this split is most of the affected codex rows (1,082 of
  # 1,620 failed non-zero), so the note must say which happened.
  @no_rollout_note "usage unrecoverable (bd-96mn8i backfill): pre-fix Probe.parse/1 bug lost " <>
                     "this probe's tokens, and no on-disk rollout JSONL was found within the " <>
                     "backfill's match window to recover them from — stays unknown, not zero."

  @no_rollout_note_failed_probe "usage unknown (bd-96mn8i backfill): this probe exited " <>
                                  "non-zero or timed out and reported no result object, so " <>
                                  "there were no tokens for the pre-fix parser to lose; no " <>
                                  "on-disk rollout JSONL was found within the backfill's match " <>
                                  "window either — stays unknown, not zero."

  @no_token_count_note "usage unrecoverable (bd-96mn8i backfill): pre-fix Probe.parse/1 bug lost " <>
                         "this probe's tokens; the matching on-disk rollout JSONL was found but " <>
                         "carries no token_count line either — stays unknown, not zero."

  @no_token_count_note_failed_probe "usage unknown (bd-96mn8i backfill): this probe exited " <>
                                      "non-zero or timed out and reported no result object, so " <>
                                      "there were no tokens for the pre-fix parser to lose; the " <>
                                      "matching on-disk rollout JSONL was found but carries no " <>
                                      "token_count line either — stays unknown, not zero."

  @type report :: %{
          scanned: non_neg_integer(),
          backfilled: non_neg_integer(),
          would_backfill: non_neg_integer(),
          no_rollout_file: non_neg_integer(),
          no_token_count: non_neg_integer(),
          unreadable: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Scan codex `usage_events` rows with `tokens_in: nil` and backfill them from
  their on-disk rollout JSONL.

  Options:

    * `:apply?` — write the rows (default `false`, dry-run)
    * `:since` / `:until` — `%DateTime{}` bounds on `occurred_at`
    * `:limit` — cap the number of rows scanned, for chipping away in batches
    * `:tolerance_ms` — passed to `CodexSessionFile.find_for_probe/4`
      (default 5000)
    * `:sessions_dir` — overrides `CodexSessionFile.sessions_dir/0`, for
      tests

  Returns a `t:report/0`.
  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)
    tolerance_ms = Keyword.get(opts, :tolerance_ms, 5_000)
    find_opts = Keyword.take(opts, [:sessions_dir])

    Event
    |> Ash.Query.filter(provider == "codex" and source == :preflight and is_nil(tokens_in))
    |> filter_since(opts[:since])
    |> filter_until(opts[:until])
    |> Ash.Query.sort(occurred_at: :asc)
    |> limit(opts[:limit])
    |> Ash.read!()
    |> Enum.reduce(blank_report(), &process_row(&1, apply?, tolerance_ms, find_opts, &2))
  end

  defp blank_report do
    %{
      scanned: 0,
      backfilled: 0,
      would_backfill: 0,
      no_rollout_file: 0,
      no_token_count: 0,
      unreadable: 0,
      failed: 0
    }
  end

  defp process_row(row, apply?, tolerance_ms, find_opts, acc) do
    acc = bump(acc, :scanned)

    case CodexSessionFile.find_for_probe(
           row.occurred_at,
           row.duration_ms,
           tolerance_ms,
           find_opts
         ) do
      :not_found ->
        if apply?, do: note_only(row, no_rollout_note_for(row))
        bump(acc, :no_rollout_file)

      {:ok, path} ->
        handle_file(row, path, apply?, acc)
    end
  end

  defp handle_file(row, path, apply?, acc) do
    case CodexSessionFile.read_totals(path) do
      {:ok, %{tokens_in: nil}} ->
        if apply?, do: note_only(row, no_token_count_note_for(row))
        bump(acc, :no_token_count)

      {:ok, totals} ->
        if apply?, do: bump(acc, apply_backfill(row, totals)), else: bump(acc, :would_backfill)

      {:error, reason} ->
        Logger.debug("CodexUsageBackfill: unreadable rollout #{path}: #{inspect(reason)}")
        bump(acc, :unreadable)
    end
  end

  # A probe with `exit_status == 0` completed and printed a result object —
  # the pre-fix parser had something to drop. Any other status (non-zero, or
  # nil for a timed-out probe that never reached `exit_status`) means the CLI
  # never reported usage in the first place, so the "parser dropped it" note
  # would be false.
  defp failed_probe?(%{exit_status: 0}), do: false
  defp failed_probe?(_row), do: true

  defp no_rollout_note_for(row) do
    if failed_probe?(row), do: @no_rollout_note_failed_probe, else: @no_rollout_note
  end

  defp no_token_count_note_for(row) do
    if failed_probe?(row), do: @no_token_count_note_failed_probe, else: @no_token_count_note
  end

  defp apply_backfill(row, totals) do
    attrs = %{
      tokens_in: totals.tokens_in,
      tokens_out: totals.tokens_out,
      cache_read_tokens: totals.cache_read_tokens,
      cost_note: @backfill_note,
      raw: totals.raw
    }

    case Ash.update(row, attrs, action: :backfill_usage) do
      {:ok, _row} ->
        :backfilled

      {:error, reason} ->
        Logger.debug("CodexUsageBackfill: update failed for #{row.id}: #{inspect(reason)}")
        :failed
    end
  end

  # Re-notes a row this pass can't recover tokens for, without touching its
  # (already-nil) token columns — `:no_rollout_file`/`:no_token_count` stay
  # the report bucket either way, this only replaces the disproven pre-fix
  # note with an honest one.
  defp note_only(row, note) do
    case Ash.update(row, %{cost_note: note}, action: :backfill_usage) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "CodexUsageBackfill: note-only update failed for #{row.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))

  defp filter_since(query, nil), do: query

  defp filter_since(query, %DateTime{} = since),
    do: Ash.Query.filter(query, occurred_at >= ^since)

  defp filter_until(query, nil), do: query

  defp filter_until(query, %DateTime{} = until),
    do: Ash.Query.filter(query, occurred_at <= ^until)

  defp limit(query, nil), do: query
  defp limit(query, n) when is_integer(n) and n > 0, do: Ash.Query.limit(query, n)
end
