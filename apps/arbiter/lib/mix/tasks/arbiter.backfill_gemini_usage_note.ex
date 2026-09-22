defmodule Mix.Tasks.Arbiter.BackfillGeminiUsageNote do
  @shortdoc "Rewrite the cost_note on historical zero-token gemini usage_events rows"
  @moduledoc """
  Rewrite `cost_note` on gemini `usage_events` rows whose `tokens_in` is nil
  because they predate bd-96mn8i's fix to `Arbiter.Usage.Probe.decoder_for/1`
  (round 2 finding 1). Unlike codex, there is no on-disk gemini session file
  to recover tokens from, so this only replaces the note — it never writes
  token columns.

  ## Usage

      mix arbiter.backfill_gemini_usage_note                    # dry-run (default)
      mix arbiter.backfill_gemini_usage_note --apply             # write the notes
      mix arbiter.backfill_gemini_usage_note --since 2026-09-14  # rows occurring on/after
      mix arbiter.backfill_gemini_usage_note --until 2026-09-21  # rows occurring before
      mix arbiter.backfill_gemini_usage_note --limit 200 --apply # chip away in batches

  See `Arbiter.Usage.GeminiUsageNote` for why no recovery is attempted.
  """

  use Mix.Task

  alias Arbiter.Usage.GeminiUsageNote

  @switches [apply: :boolean, since: :string, until: :string, limit: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    apply? = opts[:apply] == true

    backfill_opts =
      [apply?: apply?]
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Mix.Task.run("app.start")

    Mix.shell().info(banner(apply?))

    backfill_opts
    |> GeminiUsageNote.backfill()
    |> report(apply?)
    |> Mix.shell().info()
  end

  defp banner(true), do: "Rewriting gemini usage notes (writing)…"

  defp banner(false),
    do: "Rewriting gemini usage notes — DRY RUN, no writes. Re-run with --apply.\n"

  defp report(r, apply?) do
    verb = if apply?, do: "noted", else: "would note"

    """

    gemini rows scanned:  #{r.scanned}
    #{String.pad_trailing(verb <> ":", 22)}#{r.noted + r.would_note}
    write failures:        #{r.failed}
    """
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp date(nil, _flag), do: nil

  defp date(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _} -> Mix.raise("#{flag} must be an ISO8601 date or datetime, got: #{value}")
        end
    end
  end
end
