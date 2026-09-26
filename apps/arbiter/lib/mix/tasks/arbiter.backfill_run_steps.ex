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

  ## Release installs

  This is a thin CLI wrapper over `Arbiter.Release.backfill/2`, which is
  Mix-free and callable from a release install with no Elixir toolchain:

      bin/arbiter eval 'Arbiter.Release.backfill(:run_steps)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:run_steps, apply?: true)'

  It starts only Ash + the Ecto repo, never the full app-boot task ("app.start"):
  booting the full application next to a live coordinator would start a
  second endpoint on the same port, a second Autopilot and a second set of
  patrols against the same database.
  """

  use Mix.Task

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

    Mix.Task.run("app.config")

    # Validate the window before running: a typo'd --since should fail in
    # milliseconds, not after the file scan starts.
    backfill_opts =
      [apply?: opts[:apply] == true]
      |> put_opt(:repo, opts[:repo])
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Arbiter.Release.backfill(:run_steps, Keyword.put(backfill_opts, :hint, "--apply"))
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
