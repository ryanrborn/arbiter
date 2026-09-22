defmodule Mix.Tasks.Arbiter.BackfillCodexUsage do
  @shortdoc "Recover zero-token codex usage_events rows from on-disk rollout JSONL"
  @moduledoc """
  Backfill `usage_events` rows for codex probes whose live capture landed
  with `tokens_in`/`tokens_out: nil` before bd-96mn8i taught
  `Arbiter.Usage.Probe` codex's `turn.completed` wire shape (bd-96mn8i round
  2, finding 1).

  ## Usage

      mix arbiter.backfill_codex_usage                    # dry-run (default)
      mix arbiter.backfill_codex_usage --apply             # write the rows
      mix arbiter.backfill_codex_usage --since 2026-09-14  # rows occurring on/after
      mix arbiter.backfill_codex_usage --until 2026-09-21  # rows occurring before
      mix arbiter.backfill_codex_usage --limit 200 --apply # chip away in batches

  Dry-run is the default and prints exactly what a `--apply` pass would
  write. The pass only ever touches rows matching `provider == "codex" and
  is_nil(tokens_in)`, so re-running converges rather than re-writing rows a
  previous pass already recovered.

  See `Arbiter.Usage.CodexUsageBackfill` for the matching/recovery logic and
  `Arbiter.Usage.CodexSessionFile` for the on-disk rollout format.

  ## It starts the Repo, not the application

  Deliberately no `Mix.Task.run("app.start")`: booting the full application
  next to a live coordinator would start a second endpoint on the same port,
  a second Autopilot and a second set of patrols against the same database.
  Like `mix arbiter.backfill_issue_repos`, this starts only what it needs —
  the Ecto repo — so it is safe to run whether or not the server is up.
  """

  use Mix.Task

  alias Arbiter.Usage.CodexUsageBackfill

  @switches [
    apply: :boolean,
    since: :string,
    until: :string,
    limit: :integer,
    tolerance_ms: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    apply? = opts[:apply] == true

    backfill_opts =
      [apply?: apply?]
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:tolerance_ms, opts[:tolerance_ms])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    start_repo!()

    Mix.shell().info(banner(apply?))

    backfill_opts
    |> CodexUsageBackfill.backfill()
    |> report(apply?)
    |> Mix.shell().info()
  end

  # No-op when the repo is already running (an attached node / an iex session
  # that started the app), so this is safe to call either way.
  defp start_repo! do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ash)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)

    case Arbiter.Repo.start_link(pool_size: 1) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp banner(true), do: "Backfilling codex usage from on-disk rollout JSONL (writing)…"
  defp banner(false), do: "Backfilling codex usage — DRY RUN, no writes. Re-run with --apply.\n"

  defp report(r, apply?) do
    verb = if apply?, do: "backfilled", else: "would backfill"

    """

    codex rows scanned:  #{r.scanned}
    #{String.pad_trailing(verb <> ":", 22)}#{r.backfilled + r.would_backfill}
    no rollout file:      #{r.no_rollout_file}
    no token_count line:  #{r.no_token_count}
    unreadable file:      #{r.unreadable}
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
