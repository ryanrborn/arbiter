defmodule Mix.Tasks.Arbiter.MigrateRigPaths do
  @shortdoc "Migrate any workspace still keyed under the retired rig_paths config key"
  @moduledoc """
  One-off migration for the `rig_paths` → `repo_paths` config-key rename
  (bd-1e6ysj). Any workspace whose config still carries a top-level
  `rig_paths` map is silently ignored by the schema (unknown keys are
  dropped) and loses its repo map entirely, since every reader now looks
  up `repo_paths` only.

  For each workspace with a `rig_paths` key:

    1. deep-merge `rig_paths` into `repo_paths` (existing `repo_paths`
       entries win on key collision — they're presumed more current), and
    2. drop `rig_paths`.

  ## Usage

      mix arbiter.migrate_rig_paths            # dry-run
      mix arbiter.migrate_rig_paths --apply    # actually migrate

  In dry-run the affected workspaces and their resulting `repo_paths` are
  printed. No database writes happen until `--apply` is passed.
  """

  use Mix.Task

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.start")

    affected =
      Workspace
      |> Ash.read!()
      |> Enum.filter(&is_map(get_in(&1.config, ["rig_paths"])))

    if affected == [] do
      Mix.shell().info("No workspace carries rig_paths — nothing to migrate.")
    else
      for ws <- affected do
        rig_paths = ws.config["rig_paths"]
        repo_paths = ws.config["repo_paths"] || %{}
        merged = PatchConfig.deep_merge(rig_paths, repo_paths)

        if opts[:apply] == true do
          case Ash.update(ws, %{patch: %{"repo_paths" => merged}, unset_paths: ["rig_paths"]},
                 action: :patch_config
               ) do
            {:ok, _updated} ->
              Mix.shell().info("#{ws.name}: migrated -> #{inspect(merged)}")

            {:error, err} ->
              Mix.shell().error("#{ws.name}: failed -- #{inspect(err)}")
          end
        else
          Mix.shell().info("#{ws.name}: would migrate -> #{inspect(merged)}")
        end
      end

      unless opts[:apply] == true do
        Mix.shell().info("\nDry-run only. Re-run with --apply to commit.")
      end
    end
  end
end
