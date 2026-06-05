defmodule ArbiterCli.Cmd.Migrate do
  @moduledoc """
  Run Arbiter's database migrations explicitly, outside the boot process.

  Used by `arb update` to ensure migrations are applied as a visible deploy step,
  not silently by the boot migrator.
  """

  alias ArbiterCli.Cmd.Start

  @doc """
  Run all pending migrations from the given project root.

  Returns `{:ok, count}` where count is the number of migrations applied,
  or `{:error, reason}` on failure.
  """
  @spec run(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run(root) do
    Start.log_text("Running database migrations…")

    case Start.run_cmd("mix", ["arbiter.migrate"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        # Parse the JSON output from the mix task
        case parse_migration_output(output) do
          {:ok, count} ->
            {:ok, count}

          :error ->
            {:error, "Failed to parse migration output: #{output}"}
        end

      {output, _code} ->
        {:error, "Migration failed: #{output}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Could not run mix: #{inspect(e.original)}"}
  end

  defp parse_migration_output(output) do
    # mix arbiter.migrate emits Logger lines before the JSON summary line.
    # Scan for the first line that looks like a JSON object.
    json_line =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "{"))

    case json_line && Jason.decode(json_line) do
      {:ok, %{"migrations_applied" => count, "status" => "ok"}} ->
        {:ok, count}

      {:ok, %{"error" => _error, "status" => "failed"}} ->
        :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
