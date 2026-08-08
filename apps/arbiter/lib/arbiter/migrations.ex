defmodule Arbiter.Migrations do
  @moduledoc """
  Check for pending database migrations.

  Used by the doctor health check and dispatch pre-flight to surface and gate
  work when the schema is about to change.
  """

  @doc """
  Count pending migrations across all configured Ecto repos.

  Returns the total number of migrations that have been defined but not yet run.
  Returns 0 if all migrations are up to date or if the database is not set up.

  Handles the fresh-install case (no database) gracefully by catching errors
  and returning 0 rather than failing.
  """
  @spec count_pending() :: non_neg_integer()
  def count_pending do
    Application.fetch_env!(:arbiter, :ecto_repos)
    |> Enum.map(&count_pending_for_repo/1)
    |> Enum.sum()
  rescue
    # Fresh install or database not configured — no pending migrations to check.
    _ -> 0
  end

  defp count_pending_for_repo(repo) do
    # Ecto.Migrator.with_repo/2 returns {ok, result, started_apps}, where result
    # is what the callback returns. The callback returns {:ok, migrations}, so we
    # match the full 3-tuple structure.
    with {:ok, {:ok, migrations}, _apps} <- safe_get_migrations(repo) do
      migrations
      |> Enum.count(fn {_version, _name, status} -> status == :down end)
    else
      # Database not reachable or not set up — count as 0 pending
      _ -> 0
    end
  rescue
    # Catch any errors during migration check (e.g., database not running)
    _ -> 0
  end

  defp safe_get_migrations(repo) do
    Ecto.Migrator.with_repo(repo, fn _repo ->
      {:ok, Ecto.Migrator.migrations(repo)}
    end)
  rescue
    _ -> {:error, :unreachable}
  end
end
