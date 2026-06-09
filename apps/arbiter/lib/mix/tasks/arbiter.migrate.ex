defmodule Mix.Tasks.Arbiter.Migrate do
  @moduledoc """
  Run database migrations and report the count applied.

  Used by `arb update` to make migrations an explicit, reportable deploy step.
  Exit status 0 on success (whether or not migrations were applied), non-zero on failure.
  Outputs JSON to stdout for machine parsing.
  """

  use Mix.Task

  def run(_args) do
    # Get the configured repos
    repos = Application.fetch_env!(:arbiter, :ecto_repos)

    # Run migrations and collect counts
    total_applied =
      Enum.reduce(repos, 0, fn repo, acc ->
        {_ok, versions, _started} =
          Ecto.Migrator.with_repo(repo, fn r ->
            Ecto.Migrator.run(r, :up, all: true)
          end)

        acc + length(versions)
      end)

    # Output JSON result for the CLI to parse
    IO.puts(
      Jason.encode!(%{
        "migrations_applied" => total_applied,
        "status" => "ok"
      })
    )
  rescue
    err ->
      IO.puts(:stderr, "Migration failed: #{inspect(err)}")

      IO.puts(
        Jason.encode!(%{
          "error" => inspect(err),
          "status" => "failed"
        })
      )

      exit(1)
  end
end
