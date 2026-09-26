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

  ## Release installs

  This is a thin CLI wrapper over `Arbiter.Release.backfill/2`, which is
  Mix-free and callable from a release install with no Elixir toolchain:

      bin/arbiter eval 'Arbiter.Release.backfill(:gemini_usage_note)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:gemini_usage_note, apply?: true)'

  It starts only Ash + the Ecto repo, never the full app-boot task ("app.start"):
  booting the full application next to a live coordinator would start a
  second endpoint on the same port, a second Autopilot and a second set of
  patrols against the same database.
  """

  use Mix.Task

  @switches [apply: :boolean, since: :string, until: :string, limit: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    backfill_opts =
      [apply?: opts[:apply] == true]
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Arbiter.Release.backfill(:gemini_usage_note, Keyword.put(backfill_opts, :hint, "--apply"))
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
