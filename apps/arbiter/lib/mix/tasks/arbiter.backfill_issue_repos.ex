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

  ## Release installs

  This is a thin CLI wrapper over `Arbiter.Release.backfill/2`, which is
  Mix-free and callable from a release install with no Elixir toolchain:

      bin/arbiter eval 'Arbiter.Release.backfill(:issue_repos)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:issue_repos, apply?: true)'

  It starts only Ash + the Ecto repo, never the full app-boot task ("app.start"):
  booting the full application next to a live coordinator would start a
  second endpoint on the same port, a second Autopilot and a second set of
  patrols against the same database.
  """

  use Mix.Task

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    Arbiter.Release.backfill(:issue_repos, apply?: opts[:apply] == true, hint: "--apply")
  end
end
