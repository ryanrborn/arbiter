defmodule Arbiter.Release do
  @moduledoc """
  Release-time database tasks for the `arbiter` mix release.

  Mix (and therefore `mix ecto.migrate`) is not available inside a release, so
  an operator invokes these via `bin/arbiter eval Arbiter.Release.migrate`.
  """

  @app :arbiter

  @doc """
  Migrate the database to the latest version.

  The standard Phoenix mix-release migration entrypoint for deployments that
  run without Mix (the release is a standalone binary), invoked as
  `bin/arbiter eval Arbiter.Release.migrate`.

  **Only run this with the server stopped.** It opens its own writer against
  the database, and SQLite allows exactly one; against a live server it races
  the writer the server holds. `arb server deploy` deliberately does *not* call
  it for that reason (bd-bksulf) — the ordinary path is `Arbiter.Boot.Migrator`,
  which migrates synchronously during the new release's boot, before the
  endpoint opens. Reach for this eval only for a deliberate out-of-band
  migration with `systemctl --user stop arbiter.service` already done.
  """
  def migrate do
    Application.load(@app)

    for repo <- repos() do
      {:ok, _migrated_versions, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Run the workspace-config data migrations (currently `rig_paths` →
  `repo_paths`) without restarting the server.

  Called via `bin/arbiter eval Arbiter.Release.migrate_config`. Boot already
  runs these — `Arbiter.Boot.ConfigMigrator` — so a plain `arb server restart`
  is the simplest remediation; this exists because production installs are
  Mix-less releases where `mix arbiter.migrate_rig_paths` cannot run, and an
  operator staring at a broken install should not have to restart it to get
  repos back (bd-3pqzsa).

  Starts only the database layer, never the endpoint or worker fleet: an eval
  runs in a *separate* node from the live server, and booting the full app
  there would trip the single-instance guard and could disrupt in-flight
  workers. Mirrors `mix arbiter.loop.analyze`'s read-only startup.

  Prints one line per migrated workspace and returns the raw results.
  """
  def migrate_config do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _pid} = Arbiter.Repo.start_link()

    results = Arbiter.Boot.ConfigMigrator.migrate_rig_paths()

    case results do
      [] -> IO.puts("No workspace carries rig_paths — nothing to migrate.")
      results -> Enum.each(results, fn r -> IO.puts(format_config_result(r)) end)
    end

    results
  end

  defp format_config_result(%{status: :migrated} = r),
    do:
      "#{r.workspace}: migrated #{length(r.repos)} repo(s) -> repo_paths: #{Enum.join(r.repos, ", ")}"

  defp format_config_result(%{status: {:error, message}} = r),
    do: "#{r.workspace}: FAILED -- #{message}"

  defp format_config_result(r), do: "#{r.workspace}: #{inspect(r.status)}"

  @doc """
  Rollback a migration for the given repo to the specified version.

  Called via `bin/arbiter eval "Arbiter.Release.rollback(Arbiter.Repo, version)"`.
  """
  def rollback(repo, version) do
    Application.load(@app)

    {:ok, _migrated_versions, _started_apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc """
  Run a data-maintenance backfill without Mix or the full application.

  Every `mix arbiter.backfill_*` task's logic lives here now, so a release
  install — which has no Mix toolchain — can run it via
  `bin/arbiter eval 'Arbiter.Release.backfill(:codex_usage)'` (dry-run) or
  `bin/arbiter eval 'Arbiter.Release.backfill(:codex_usage, apply?: true)'`.
  The Mix tasks under `lib/mix/tasks/arbiter.backfill_*.ex` are thin CLI
  wrappers over these same clauses for dev/source installs.

  Starts only Ash + `Arbiter.Repo` (`start_release_repo!/0`), never the full
  `Arbiter.Application` tree — booting the endpoint, Autopilot, and patrols
  a second time next to a live coordinator would fight it over the same
  database and port. Safe to call from an attached node that already has
  the app running too, since the repo start is a no-op in that case.

  Every backfill defaults to a dry run (no writes; reports what it would
  change) unless `apply?: true` is passed. Supported names and their
  option keys mirror the corresponding library module:

    * `:codex_usage` → `Arbiter.Usage.CodexUsageBackfill.backfill/1`
      (`:apply?`, `:since`, `:until`, `:limit`, `:tolerance_ms`)
    * `:gemini_usage_note` → `Arbiter.Usage.GeminiUsageNote.backfill/1`
      (`:apply?`, `:since`, `:until`, `:limit`)
    * `:issue_repos` → `Arbiter.Tasks.RepoBackfill.plan/0` + `apply!/1`
      (`:apply?`)
    * `:run_steps` → `Arbiter.Workers.StepBackfill.backfill/1`
      (`:apply?`, `:repo`, `:since`, `:until`, `:limit`)
    * `:task_statuses` → `Arbiter.Tasks.StatusBackfill.proposals/1` +
      `apply!/1` (`:apply?`, `:branch`, `:repo_path`) — `:repo_path` defaults
      to `File.cwd!()`, which under `bin/arbiter eval` is wherever the
      operator invoked `bin/arbiter`, not the arbiter checkout. Always pass
      it explicitly in a release eval, e.g.
      `bin/arbiter eval 'Arbiter.Release.backfill(:task_statuses, repo_path: "/path/to/arbiter")'`

  Returns the underlying module's raw result and prints a short summary to
  stdout for the `bin/arbiter eval` operator.
  """
  @spec backfill(atom(), keyword()) :: term()
  def backfill(name, opts \\ [])

  def backfill(:codex_usage, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Usage.CodexUsageBackfill.backfill(opts)

    IO.puts(banner("codex usage", apply?, opts[:hint]))

    IO.puts("""

    codex rows scanned:  #{result.scanned}
    #{String.pad_trailing(if(apply?, do: "backfilled", else: "would backfill") <> ":", 22)}#{result.backfilled + result.would_backfill}
    no rollout file:      #{result.no_rollout_file}
    no token_count line:  #{result.no_token_count}
    unreadable file:      #{result.unreadable}
    write failures:        #{result.failed}
    """)

    result
  end

  def backfill(:gemini_usage_note, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Usage.GeminiUsageNote.backfill(opts)

    IO.puts(banner("gemini usage note", apply?, opts[:hint]))

    IO.puts("""

    gemini rows scanned:  #{result.scanned}
    #{String.pad_trailing(if(apply?, do: "noted", else: "would note") <> ":", 22)}#{result.noted + result.would_note}
    write failures:        #{result.failed}
    """)

    result
  end

  def backfill(:issue_repos, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    plan = Arbiter.Tasks.RepoBackfill.plan()

    if apply? do
      reports = Arbiter.Tasks.RepoBackfill.apply!(plan)
      IO.puts(banner("issue repos", true, opts[:hint]))
      emit_issue_repos_report(reports, :apply)
      reports
    else
      IO.puts(banner("issue repos", false, opts[:hint]))
      emit_issue_repos_report(plan, :dry_run)
      plan
    end
  end

  def backfill(:run_steps, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Workers.StepBackfill.backfill(opts)

    IO.puts(banner("run steps", apply?, opts[:hint]))

    IO.puts("""

    runs scanned:      #{result.scanned}
    steps #{String.pad_trailing(if(apply?, do: "inserted", else: "would insert") <> ":", 13)}#{result.inserted}
    already present:   #{result.existing}
    no session file:   #{result.no_session_file}
    no session id:     #{result.no_session_id}
    unreadable file:   #{result.unreadable}
    write failures:    #{result.failed}
    """)

    result
  end

  def backfill(:task_statuses, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)
    hint = opts[:hint] || "apply?: true / --apply"
    proposals_opts = Keyword.take(opts, [:branch, :repo_path, :git_log_lines])
    proposals = Arbiter.Tasks.StatusBackfill.proposals(proposals_opts)

    cond do
      proposals == [] ->
        IO.puts("No drifted tasks found. Nothing to do.")
        {[], []}

      apply? ->
        IO.puts("Closing #{length(proposals)} task(s):")
        emit_task_statuses_table(proposals)
        {closed, errors} = Arbiter.Tasks.StatusBackfill.apply!(proposals)
        IO.puts("\nClosed #{length(closed)} task(s).")

        unless errors == [] do
          IO.puts(:stderr, "Failed on #{length(errors)} task(s):")
          for {id, reason} <- errors, do: IO.puts(:stderr, "  #{id}: #{inspect(reason)}")
        end

        {closed, errors}

      true ->
        IO.puts("Would close #{length(proposals)} task(s):")
        emit_task_statuses_table(proposals)
        IO.puts("\nDry-run only. Pass #{hint} to commit these changes.")
        proposals
    end
  end

  defp emit_task_statuses_table(proposals) do
    width = proposals |> Enum.map(&String.length(&1.task_id)) |> Enum.max(fn -> 0 end)

    for p <- proposals do
      padded = String.pad_trailing(p.task_id, width)
      short_sha = String.slice(p.commit_sha, 0, 7)
      IO.puts("  #{padded}  #{short_sha}  #{p.commit_subject}")
    end
  end

  defp emit_issue_repos_report(reports, mode) do
    IO.puts(issue_repos_header(mode))

    for report <- reports, report.null_repo_count > 0 or report.resolved_repo != nil do
      IO.puts("  " <> issue_repos_line(report, mode))

      for {id, message} <- report.errors do
        IO.puts(:stderr, "      #{id}: #{message}")
      end
    end

    IO.puts("\n" <> issue_repos_totals(reports, mode))
  end

  defp issue_repos_header(:dry_run), do: "Issues with a null repo, by workspace:\n"
  defp issue_repos_header(:apply), do: "Backfilling repo by workspace:\n"

  defp issue_repos_line(%{resolved_repo: nil} = r, _mode) do
    "#{r.workspace_name}: #{r.null_repo_count} null — LEFT NULL " <>
      "(no single repo and no default_repo; set one and re-run)"
  end

  defp issue_repos_line(r, :dry_run),
    do: "#{r.workspace_name}: #{r.null_repo_count} null → #{r.resolved_repo}"

  defp issue_repos_line(r, :apply) do
    "#{r.workspace_name}: set #{r.updated} to #{r.resolved_repo}" <>
      if(r.errors == [], do: "", else: " (#{length(r.errors)} failed)")
  end

  defp issue_repos_totals(reports, :dry_run) do
    would = reports |> Enum.map(& &1.null_repo_count) |> Enum.sum()
    left = Arbiter.Tasks.RepoBackfill.remaining_null_count(reports)
    "#{would - left} issue(s) would be backfilled; #{left} would remain null."
  end

  defp issue_repos_totals(reports, :apply) do
    updated = reports |> Enum.map(& &1.updated) |> Enum.sum()

    "Backfilled #{updated} issue(s); #{Arbiter.Tasks.RepoBackfill.remaining_null_count(reports)} remain null."
  end

  defp banner(label, true, _hint), do: "Backfilling #{label} (writing)…"

  defp banner(label, false, hint) do
    "Backfilling #{label} — DRY RUN, no writes. Pass #{hint || "apply?: true / --apply"} to write.\n"
  end

  @doc """
  Load config and start only Ash + `Arbiter.Repo` (`pool_size: 1`), never
  the full `Arbiter.Application` tree — no endpoint, no Autopilot, no
  patrols. Shared by every `backfill/2` clause and safe to call repeatedly
  or from a node that already has the app running (`start_link` returning
  `{:error, {:already_started, _}}` is treated as success).
  """
  @spec start_release_repo! :: :ok
  def start_release_repo! do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ash)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)

    case Arbiter.Repo.start_link(pool_size: 1) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
