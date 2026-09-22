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
  """

  require Ash.Query
  require Logger

  alias Arbiter.Usage.Event

  @note "usage unrecoverable (bd-96mn8i backfill): pre-fix Probe.decoder_for/1 didn't " <>
          "recognize gemini's `stats` shape, so the live probe wrote no tokens for this row " <>
          "and no on-disk gemini session file exists to recover them from afterward — stays " <>
          "unknown, not zero."

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

    case Ash.update(row, %{cost_note: @note}, action: :backfill_usage) do
      {:ok, _row} ->
        bump(acc, :noted)

      {:error, reason} ->
        Logger.debug("GeminiUsageNote: update failed for #{row.id}: #{inspect(reason)}")
        bump(acc, :failed)
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
