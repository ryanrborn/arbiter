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
