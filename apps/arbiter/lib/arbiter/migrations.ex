defmodule Arbiter.Migrations do
  @moduledoc """
  Check for pending database migrations.

  Used by the doctor health check and dispatch pre-flight to surface and gate
  work when the schema is about to change.

  `arb server doctor` reads pending state through the running server's HTTP
  API. In the documented `systemctl --user restart arbiter` deploy flow, boot
  applies migrations before the server accepts traffic, so that check will
  rarely observe a non-zero count in that flow. It still has real value in
  dev (`mix phx.server` does not auto-migrate). The dispatch-side gate here is
  in-process and unaffected by this limitation.
  """

  @doc """
  Count pending migrations across all configured Ecto repos.

  Returns {:ok, total_count} if all repos are checked successfully, where
  total_count is the number of defined but unapplied migrations.

  Returns {:error, reason} if any repo is unreachable or if the check fails
  for any other reason.

  Handles the fresh-install case (no database) gracefully: when repos exist
  but the database is not yet set up, returns {:error, :unreachable} rather
  than failing hard. Callers must decide whether to block or proceed.
  """
  @spec count_pending() :: {:ok, non_neg_integer()} | {:error, atom()}
  def count_pending do
    Application.fetch_env!(:arbiter, :ecto_repos)
    |> Enum.map(&count_pending_for_repo/1)
    |> collect_results()
  rescue
    # Configuration error or repos not defined — cannot check.
    _ -> {:error, :configuration}
  end

  defp count_pending_for_repo(repo) do
    repo
    |> safe_get_migrations()
    |> extract_pending_count()
  end

  # Fold a list of {:ok, count} | {:error, reason} results into a single result.
  # If all succeed, sum the counts. If any fail, return the first error.
  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, 0}, fn result, {:ok, total} ->
      case result do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  # Parses the raw return of `Ecto.Migrator.with_repo/2` and counts :down
  # migrations. `with_repo/2` returns a 3-tuple, `{:ok, callback_result,
  # started_apps}` — NOT a 2-tuple — and the callback here returns `{:ok,
  # migrations}`, so a success looks like `{:ok, {:ok, migrations}, apps}`.
  # Exposed (not private) so the pattern-matching itself — the exact shape
  # that was previously wrong — can be tested directly without a live
  # database connection.
  @spec extract_pending_count(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def extract_pending_count({:ok, {:ok, migrations}, _started_apps}) do
    count = Enum.count(migrations, fn {status, _version, _name} -> status == :down end)
    {:ok, count}
  end

  def extract_pending_count({:error, reason}), do: {:error, reason}

  def extract_pending_count(_other), do: {:error, :invalid_shape}

  defp safe_get_migrations(repo) do
    Ecto.Migrator.with_repo(repo, fn _repo ->
      {:ok, Ecto.Migrator.migrations(repo)}
    end)
  rescue
    _ -> {:error, :unreachable}
  catch
    :exit, _ -> {:error, :unreachable}
  end
end
