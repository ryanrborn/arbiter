defmodule Arbiter.Usage.GeminiUsageNote do
  @moduledoc """
  Rewrite the `cost_note` on historical gemini `usage_events` rows that
  predate bd-96mn8i's fix to `Arbiter.Usage.Probe.decoder_for/1` (round 2
  finding 1).

  Unlike codex, there is no on-disk gemini session file this module can
  recover tokens from (`Arbiter.Usage.CodexSessionFile` has no gemini
  counterpart — the gemini CLI's own session transcript does not carry a
  parsed token total the way codex's `rollout-*.jsonl` does). So this module
  does not attempt recovery; it only replaces the pre-fix note.

  Every affected row was written by a probe process whose stdout the pre-fix
  `Probe.parse/1` genuinely could not turn into tokens — not because gemini
  reported nothing (`Arbiter.Usage.Probe.decoder_for/1`'s gemini branch now
  reads the CLI's `stats` field, which was present in the same run all
  along), but because the live parser didn't recognize gemini's `stats`
  shape before this fix. That's the same "disproven by this branch's own
  fix" situation codex's `Arbiter.Usage.CodexUsageBackfill.@no_rollout_note`
  addresses — this module is the gemini-side, recovery-less equivalent: it
  only touches the note, so these rows stay `tokens_in: nil` (already the
  correct "unknown" representation) and are simply told the truth about why.

  Only `provider == "gemini" and source == :preflight and
  is_nil(tokens_in)` rows are touched — `source: :task` gemini rows already
  read tokens correctly (round 2 finding 2's live-DB check: 35 of 48
  `source: :task` rows non-zero) and are never in scope here.

  bd-96mn8i round 9 finding 1: the "parser didn't recognize the shape" story
  is only true for a row whose probe actually completed (`exit_status == 0`)
  and therefore printed a `stats` payload for the pre-fix decoder to fail on.
  A probe that exited non-zero, or timed out (`exit_status` nil), never
  reported a result object at all — nothing for the decoder to misparse.
  Against the live ledger this is the tiny minority for gemini (1,243 of
  1,257 affected rows have `exit_status == 0`, so the "shape" story holds for
  almost all of them), but the note still has to say which happened per row
  rather than assert the majority case unconditionally.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Usage.Event

  @note "usage unrecoverable (bd-96mn8i backfill): pre-fix Probe.decoder_for/1 didn't " <>
          "recognize gemini's `stats` shape, so the live probe wrote no tokens for this row " <>
          "and no on-disk gemini session file exists to recover them from afterward — stays " <>
          "unknown, not zero."

  @note_failed_probe "usage unknown (bd-96mn8i backfill): this probe exited non-zero or timed " <>
                       "out and reported no result object, so there were no tokens for the " <>
                       "pre-fix decoder to misparse in the first place; no on-disk gemini " <>
                       "session file exists to recover them from either — stays unknown, not " <>
                       "zero."

  @type report :: %{
          scanned: non_neg_integer(),
          noted: non_neg_integer(),
          would_note: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Scan gemini preflight `usage_events` rows with `tokens_in: nil` and rewrite
  their `cost_note` to an honest, non-recovery note.

  Options:

    * `:apply?` — write the rows (default `false`, dry-run)
    * `:since` / `:until` — `%DateTime{}` bounds on `occurred_at`
    * `:limit` — cap the number of rows scanned, for chipping away in batches

  Returns a `t:report/0`.
  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    Event
    |> Ash.Query.filter(provider == "gemini" and source == :preflight and is_nil(tokens_in))
    |> filter_since(opts[:since])
    |> filter_until(opts[:until])
    |> Ash.Query.sort(occurred_at: :asc)
    |> limit(opts[:limit])
    |> Ash.read!()
    |> Enum.reduce(blank_report(), &process_row(&1, apply?, &2))
  end

  defp blank_report, do: %{scanned: 0, noted: 0, would_note: 0, failed: 0}

  defp process_row(_row, false, acc), do: acc |> bump(:scanned) |> bump(:would_note)

  defp process_row(row, true, acc) do
    acc = bump(acc, :scanned)

    case Ash.update(row, %{cost_note: note_for(row)}, action: :backfill_usage) do
      {:ok, _row} ->
        bump(acc, :noted)

      {:error, reason} ->
        Logger.debug("GeminiUsageNote: update failed for #{row.id}: #{inspect(reason)}")
        bump(acc, :failed)
    end
  end

  # See the round 9 finding 1 moduledoc note: the "decoder didn't recognize
  # the shape" story only holds for a probe that actually completed and
  # printed a result object.
  defp note_for(%{exit_status: 0}), do: @note
  defp note_for(_row), do: @note_failed_probe

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
