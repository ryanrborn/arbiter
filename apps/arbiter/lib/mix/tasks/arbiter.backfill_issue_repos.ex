defmodule Mix.Tasks.Arbiter.BackfillIssueRepos do
  @shortdoc "Set repo on issues that predate create-time repo resolution"
  @moduledoc """
  Backfill `repo` on every issue whose `repo` is null, from its workspace's
  only configured repo or its `default_repo` (bd-9dwbvt).

  Issues in a workspace with neither — no `repo_paths` at all, or several
  repos and no `default_repo` — are left null and reported per workspace, so
  you can set `default_repo` and re-run.

  ## Usage

      mix arbiter.backfill_issue_repos           # dry-run (prints the plan)
      mix arbiter.backfill_issue_repos --apply   # write it

  Idempotent: only null-repo rows are ever selected, so a second run is a
  no-op. See `Arbiter.Tasks.RepoBackfill` for why this is a mix task rather
  than a data migration.

  ## It starts the Repo, not the application

  Deliberately no `Mix.Task.run("app.start")`: booting the full application
  next to a live coordinator would start a second endpoint on the same port,
  a second Autopilot and a second set of patrols against the same database.
  Like `mix arbiter.migrate`, this starts only what it needs — the Ecto repo —
  so it is safe to run whether or not the server is up.
  """

  use Mix.Task

  alias Arbiter.Tasks.RepoBackfill

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    start_repo!()

    plan = RepoBackfill.plan()

    if opts[:apply] == true do
      reports = RepoBackfill.apply!(plan)
      emit(reports, :apply)
    else
      emit(plan, :dry_run)
      Mix.shell().info("\nDry-run only. Re-run with --apply to write these repos.")
    end
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

  defp emit(reports, mode) do
    Mix.shell().info(header(mode))

    for report <- reports, report.null_repo_count > 0 or report.resolved_repo != nil do
      Mix.shell().info("  " <> line(report, mode))

      for {id, message} <- report.errors do
        Mix.shell().error("      #{id}: #{message}")
      end
    end

    Mix.shell().info("\n" <> totals(reports, mode))
  end

  defp header(:dry_run), do: "Issues with a null repo, by workspace:\n"
  defp header(:apply), do: "Backfilling repo by workspace:\n"

  defp line(%{resolved_repo: nil} = r, _mode) do
    "#{r.workspace_name}: #{r.null_repo_count} null — LEFT NULL " <>
      "(no single repo and no default_repo; set one and re-run)"
  end

  defp line(r, :dry_run),
    do: "#{r.workspace_name}: #{r.null_repo_count} null → #{r.resolved_repo}"

  defp line(r, :apply) do
    "#{r.workspace_name}: set #{r.updated} to #{r.resolved_repo}" <>
      if(r.errors == [], do: "", else: " (#{length(r.errors)} failed)")
  end

  defp totals(reports, :dry_run) do
    would = reports |> Enum.map(& &1.null_repo_count) |> Enum.sum()
    left = RepoBackfill.remaining_null_count(reports)
    "#{would - left} issue(s) would be backfilled; #{left} would remain null."
  end

  defp totals(reports, :apply) do
    updated = reports |> Enum.map(& &1.updated) |> Enum.sum()
    "Backfilled #{updated} issue(s); #{RepoBackfill.remaining_null_count(reports)} remain null."
  end
end
