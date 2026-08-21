defmodule Mix.Tasks.Arbiter.BackfillRunSteps do
  @shortdoc "Reconstruct typed tool-call step rows from on-disk Claude session files"
  @moduledoc """
  Backfill `worker_run_steps` for runs that finished before live step capture
  existed (bd-apwfmy, Phase 2).

  Live capture only sees runs that happen after it ships. Every earlier run's
  tool calls are still on disk in Claude Code's own session JSONL — the same
  file the token accounting already reads — so they can be promoted into
  typed, queryable rows instead of staying locked in transcript prose.

  ## Usage

      mix arbiter.backfill_run_steps                        # dry-run (default)
      mix arbiter.backfill_run_steps --apply                # write the rows
      mix arbiter.backfill_run_steps --repo arbiter         # one repo
      mix arbiter.backfill_run_steps --since 2026-07-01     # runs started on/after
      mix arbiter.backfill_run_steps --until 2026-08-01     # runs started before
      mix arbiter.backfill_run_steps --limit 200 --apply    # chip away in batches

  Dry-run is the default and prints exactly what a `--apply` pass would
  insert. The pass is idempotent — it skips every `tool_use_id` already
  stored for a run, live-captured ones included — so re-running converges
  rather than duplicating, and `--limit` batches make forward progress.

  ## Reading the report

  `no session file` and `no session id` are not failures, they are coverage:
  a run whose session file has been reaped simply cannot be reconstructed,
  and a report that hides that number is worse than one that shows it.
  Rows written here are tagged `source: "backfill"`; see
  `Arbiter.Workers.StepBackfill` for how their timing and redaction differ
  from live capture.
  """

  use Mix.Task

  alias Arbiter.Workers.StepBackfill

  @switches [
    apply: :boolean,
    repo: :string,
    since: :string,
    until: :string,
    limit: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    apply? = opts[:apply] == true

    # Validate the window before booting the app: a typo'd --since should
    # fail in milliseconds, not after the supervision tree is up.
    backfill_opts =
      [apply?: apply?]
      |> put_opt(:repo, opts[:repo])
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Mix.Task.run("app.start")

    Mix.shell().info(banner(apply?))

    backfill_opts
    |> StepBackfill.backfill()
    |> report(apply?)
    |> Mix.shell().info()
  end

  defp banner(true), do: "Backfilling run steps from on-disk session files (writing)…"
  defp banner(false), do: "Backfilling run steps — DRY RUN, no writes. Re-run with --apply.\n"

  defp report(r, apply?) do
    verb = if apply?, do: "inserted", else: "would insert"

    """

    runs scanned:      #{r.scanned}
    steps #{String.pad_trailing(verb <> ":", 13)}#{r.inserted}
    already present:   #{r.existing}
    no session file:   #{r.no_session_file}
    no session id:     #{r.no_session_id}
    unreadable file:   #{r.unreadable}
    write failures:    #{r.failed}
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
