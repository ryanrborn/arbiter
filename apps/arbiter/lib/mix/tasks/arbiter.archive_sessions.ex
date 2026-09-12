defmodule Mix.Tasks.Arbiter.ArchiveSessions do
  @shortdoc "Rescue on-disk agent session JSONLs into the durable log root"
  @moduledoc """
  One-time sweep that archives the agent CLI's own session JSONL for runs that
  finished before live archiving shipped (bd-db0p38).

  The session JSONL is the only full-fidelity record of a run — every tool
  input in full, every tool result untruncated, thinking blocks, per-message
  token usage. Arbiter read it and never kept it, and **Claude Code prunes it
  at ~21 days**. So this is a race, not a chore: whatever is still on disk
  when you run this is saved, and whatever isn't is gone for good.

  ## Usage

      mix arbiter.archive_sessions                      # dry-run (default)
      mix arbiter.archive_sessions --apply              # write the archives
      mix arbiter.archive_sessions --repo arbiter       # one repo
      mix arbiter.archive_sessions --since 2026-08-01   # runs started on/after
      mix arbiter.archive_sessions --until 2026-09-01   # runs started before
      mix arbiter.archive_sessions --limit 500 --apply  # chip away in batches
      mix arbiter.archive_sessions --force --apply      # re-archive existing

  Idempotent: a run that already has an archive is skipped, so re-running
  converges. `--force` re-archives anyway (e.g. after widening the redaction
  list).

  ## Reading the report

  `no session file` is the loss this task exists to bound — the CLI already
  pruned it. `no config dir` is *not* a loss: that column is Claude-only, so a
  run without one ran on another provider and its session lives in that
  provider's own store.

  ## The archives are secret-bearing

  Files are written `0600` under `output_log_root` (best-effort `0700`), and
  the content is redacted only against the workspace's *current* secret
  values — weaker than the live path, which redacts against the run's own.
  See `docs/operations/session-archive.md`.
  """

  use Mix.Task

  alias Arbiter.Workers.SessionArchiveBackfill

  @switches [
    apply: :boolean,
    force: :boolean,
    repo: :string,
    since: :string,
    until: :string,
    limit: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    apply? = opts[:apply] == true

    # Validate the window before booting the app: a typo'd --since should fail
    # in milliseconds, not after the supervision tree is up.
    sweep_opts =
      [apply?: apply?, force: opts[:force] == true]
      |> put_opt(:repo, opts[:repo])
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Mix.Task.run("app.start")

    Mix.shell().info(banner(apply?))

    sweep_opts
    |> SessionArchiveBackfill.backfill()
    |> report(apply?)
    |> Mix.shell().info()
  end

  defp banner(true), do: "Archiving on-disk session JSONLs into the durable log root (writing)…"

  defp banner(false),
    do: "Archiving session JSONLs — DRY RUN, no writes. Re-run with --apply.\n"

  defp report(r, apply?) do
    verb = if apply?, do: "archived", else: "would archive"

    """

    runs scanned:        #{r.scanned}
    runs #{String.pad_trailing(verb <> ":", 16)}#{r.archived}
    already archived:    #{r.already_archived}
    subagent files:      #{r.subagents}
    no session file:     #{r.no_session_file}   (pruned by the CLI — irrecoverable)
    no session id:       #{r.no_session_id}
    no config dir:       #{r.no_config_dir}   (non-Claude run — nothing was lost)
    oversized (skipped): #{r.too_large}
    errors:              #{r.error}
    bytes read:          #{human(r.bytes_in)}
    bytes written:       #{human(r.bytes_out)}#{ratio(r)}
    """
  end

  defp ratio(%{bytes_in: bin, bytes_out: bout}) when bin > 0 and bout > 0 do
    "   (#{Float.round(bin / bout, 1)}:1)"
  end

  defp ratio(_r), do: ""

  defp human(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp human(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp human(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

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
