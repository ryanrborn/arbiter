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
    repo
    |> safe_get_migrations()
    |> extract_pending_count()
  rescue
    # Catch any errors during migration check (e.g., database not running)
    _ -> 0
  end

  @doc false
  # Parses the raw return of `Ecto.Migrator.with_repo/2` and counts :down
  # migrations. `with_repo/2` returns a 3-tuple, `{:ok, callback_result,
  # started_apps}` — NOT a 2-tuple — and the callback here returns `{:ok,
  # migrations}`, so a success looks like `{:ok, {:ok, migrations}, apps}`.
  # Exposed (not private) so the pattern-matching itself — the exact shape
  # that was previously wrong — can be tested directly without a live
  # database connection.
  @spec extract_pending_count(term()) :: non_neg_integer()
  def extract_pending_count({:ok, {:ok, migrations}, _started_apps}) do
    Enum.count(migrations, fn {_version, _name, status} -> status == :down end)
  end

  def extract_pending_count(_other), do: 0

  defp safe_get_migrations(repo) do
    Ecto.Migrator.with_repo(repo, fn _repo ->
      {:ok, Ecto.Migrator.migrations(repo)}
    end)
  rescue
    _ -> {:error, :unreachable}
  end
end
