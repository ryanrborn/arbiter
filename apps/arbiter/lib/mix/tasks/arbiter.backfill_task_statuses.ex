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
  """

  use Mix.Task

  alias Arbiter.Tasks.StatusBackfill

  @switches [apply: :boolean, branch: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.start")

    proposals_opts =
      []
      |> maybe_put(opts, :branch)

    proposals = StatusBackfill.proposals(proposals_opts)

    cond do
      proposals == [] ->
        Mix.shell().info("No drifted tasks found. Nothing to do.")

      opts[:apply] == true ->
        Mix.shell().info(banner(proposals, :apply))
        emit_table(proposals)
        {closed, errors} = StatusBackfill.apply!(proposals)
        Mix.shell().info("\nClosed #{length(closed)} task(s).")

        unless errors == [] do
          Mix.shell().error("Failed on #{length(errors)} task(s):")

          for {id, reason} <- errors do
            Mix.shell().error("  #{id}: #{inspect(reason)}")
          end
        end

      true ->
        Mix.shell().info(banner(proposals, :dry_run))
        emit_table(proposals)
        Mix.shell().info("\nDry-run only. Re-run with --apply to commit these changes.")
    end
  end

  defp banner(proposals, :dry_run),
    do: "Would close #{length(proposals)} task(s):\n"

  defp banner(proposals, :apply),
    do: "Closing #{length(proposals)} task(s):\n"

  defp emit_table(proposals) do
    width = proposals |> Enum.map(&String.length(&1.task_id)) |> Enum.max(fn -> 0 end)

    for p <- proposals do
      padded = String.pad_trailing(p.task_id, width)
      short_sha = String.slice(p.commit_sha, 0, 7)
      Mix.shell().info("  #{padded}  #{short_sha}  #{p.commit_subject}")
    end
  end

  defp maybe_put(acc, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> Keyword.put(acc, key, val)
      :error -> acc
    end
  end
end
