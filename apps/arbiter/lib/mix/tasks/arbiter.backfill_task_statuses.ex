defmodule Mix.Tasks.Arbiter.BackfillTaskStatuses do
  @shortdoc "Close tasks that have feat() commits on main but are still :open"
  @moduledoc """
  Walk `git log` for `feat(<task-id>)` commits on a branch and close any
  matching tasks still in `:open` / `:in_progress` status.

  This is a recovery tool for the task-status drift the cutover postmortem
  documented: the original Dolt source-of-truth fell behind during
  late-Phase implementation, and the importer carried stale `:open`
  statuses forward into Postgres.

  ## Usage

      mix arbiter.backfill_task_statuses              # dry-run (prints proposals)
      mix arbiter.backfill_task_statuses --apply      # actually close tasks
      mix arbiter.backfill_task_statuses --branch dev # use a different branch

  ## What you see in dry-run

  A list of tasks that would be closed, with the commit SHA and subject
  that justified each closure. No writes happen. Review the list, then
  re-run with `--apply` to commit the changes.

  ## Release installs

  This is a thin CLI wrapper over `Arbiter.Release.backfill/2`, which is
  Mix-free and callable from a release install with no Elixir toolchain:

      bin/arbiter eval 'Arbiter.Release.backfill(:task_statuses)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:task_statuses, apply?: true)'

  It starts only Ash + the Ecto repo, never the full app-boot task ("app.start"):
  booting the full application next to a live coordinator would start a
  second endpoint on the same port, a second Autopilot and a second set of
  patrols against the same database.
  """

  use Mix.Task

  @switches [apply: :boolean, branch: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    backfill_opts =
      [apply?: opts[:apply] == true]
      |> maybe_put(opts, :branch)

    Arbiter.Release.backfill(:task_statuses, Keyword.put(backfill_opts, :hint, "--apply"))
  end

  defp maybe_put(acc, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> Keyword.put(acc, key, val)
      :error -> acc
    end
  end
end
