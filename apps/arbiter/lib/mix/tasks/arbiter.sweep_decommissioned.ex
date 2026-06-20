defmodule Mix.Tasks.Arbiter.SweepDecommissioned do
  @shortdoc "Bulk-close tasks obsoleted by the GT → arbiter cutover"
  @moduledoc """
  Bulk-close tasks orphaned by the cutover from the original Go GT system.
  See `Arbiter.Tasks.DecommissionSweep` for the pattern list and the
  keep-list.

  ## Usage

      mix arbiter.sweep_decommissioned                # dry-run
      mix arbiter.sweep_decommissioned --apply        # actually close

  In dry-run the matched tasks are grouped by category and printed. No
  database writes happen until `--apply` is passed.
  """

  use Mix.Task

  alias Arbiter.Tasks.DecommissionSweep

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.start")

    proposals = DecommissionSweep.proposals()

    cond do
      proposals == [] ->
        Mix.shell().info("No matching tasks — sweep is a no-op.")

      opts[:apply] == true ->
        Mix.shell().info(
          "Closing #{length(proposals)} task(s) across #{count_categories(proposals)} categories:\n"
        )

        print_table(proposals)
        {closed, errors} = DecommissionSweep.apply!(proposals)
        Mix.shell().info("\nClosed #{length(closed)} task(s).")

        unless errors == [] do
          Mix.shell().error("Failed on #{length(errors)} task(s):")

          for {id, reason} <- errors do
            Mix.shell().error("  #{id}: #{inspect(reason)}")
          end
        end

      true ->
        Mix.shell().info(
          "Would close #{length(proposals)} task(s) across #{count_categories(proposals)} categories:\n"
        )

        print_table(proposals)
        Mix.shell().info("\nDry-run only. Re-run with --apply to commit.")
    end
  end

  defp count_categories(proposals) do
    proposals |> Enum.map(& &1.category) |> Enum.uniq() |> length()
  end

  defp print_table(proposals) do
    width = proposals |> Enum.map(&String.length(&1.task_id)) |> Enum.max(fn -> 0 end)

    proposals
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, items} -> {-length(items), category} end)
    |> Enum.each(fn {category, items} ->
      Mix.shell().info("#{category} (#{length(items)}):")

      for p <- items do
        padded = String.pad_trailing(p.task_id, width)
        Mix.shell().info("  #{padded}  #{truncate(p.title, 100)}")
      end

      Mix.shell().info("")
    end)
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end
end
