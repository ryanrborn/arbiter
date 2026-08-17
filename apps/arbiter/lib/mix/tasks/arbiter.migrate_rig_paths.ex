defmodule Mix.Tasks.Arbiter.MigrateRigPaths do
  @shortdoc "Migrate any workspace still keyed under the retired rig_paths config key"
  @moduledoc """
  Operator-facing front end for the `rig_paths` → `repo_paths` config-key
  rename (bd-1e6ysj). Any workspace whose config still carries a top-level
  `rig_paths` map loses its repo map entirely, since every reader now looks up
  `repo_paths` only.

  The migration itself lives in `Arbiter.Boot.ConfigMigrator` and runs
  automatically on every boot of the primary instance (bd-3pqzsa) — relying on
  an operator to remember a one-off task is what let a live install run three
  days with zero repos resolved. This task remains useful for two things: a
  dry-run preview of what a boot would do, and migrating without a restart.

  ## Usage

      mix arbiter.migrate_rig_paths            # dry-run
      mix arbiter.migrate_rig_paths --apply    # actually migrate

  In dry-run the affected workspaces and their resulting `repo_paths` are
  printed. No database writes happen until `--apply` is passed.
  """

  use Mix.Task

  alias Arbiter.Boot.ConfigMigrator

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.start")

    apply? = opts[:apply] == true

    case ConfigMigrator.migrate_rig_paths(apply?: apply?) do
      [] ->
        Mix.shell().info("No workspace carries rig_paths — nothing to migrate.")

      results ->
        Enum.each(results, &report/1)

        unless apply? do
          Mix.shell().info("\nDry-run only. Re-run with --apply to commit.")
        end
    end
  end

  defp report(%{status: :migrated} = r),
    do: Mix.shell().info("#{r.workspace}: migrated -> #{inspect(r.repo_paths)}")

  defp report(%{status: :dry_run} = r),
    do: Mix.shell().info("#{r.workspace}: would migrate -> #{inspect(r.repo_paths)}")

  defp report(%{status: {:error, message}} = r),
    do: Mix.shell().error("#{r.workspace}: failed -- #{message}")
end
