defmodule Arbiter.Release do
  @app :arbiter

  @doc """
  Migrate the database to the latest version.

  Called via `bin/arbiter eval Arbiter.Release.migrate` during release deploy.
  This is the standard Phoenix mix-release migration entrypoint for deployments
  that run without Mix (the release is a standalone binary).

  For the boot-time automatic migration, see Arbiter.Boot.Migrator.
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
