defmodule ArbiterCli.Cmd.Server do
  @moduledoc """
  `arb server <verb>` — manage the Arbiter server stack (SQLite + Phoenix).

      arb server start    [--timeout SECONDS] [--json]
      arb server restart  [--timeout SECONDS] [--json]
      arb server deploy   [--timeout SECONDS] [--json] [--force]
                          git pull --ff-only main → migrate → rebuild CLI
                          if changed → restart Phoenix.
      arb server migrate  [--json]
                          run pending database migrations as an explicit step.
      arb server doctor   [--json]
      arb server version  [--json]
  """

  alias ArbiterCli.{Cmd, Output}

  def run(argv) do
    case argv do
      ["start" | rest] -> Cmd.Start.run(rest)
      ["restart" | rest] -> Cmd.Restart.run(rest)
      ["deploy" | rest] -> Cmd.Update.deploy(rest)
      ["migrate" | rest] -> migrate(rest)
      ["doctor" | rest] -> Cmd.Doctor.run(rest)
      ["version" | rest] -> Cmd.Version.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("server requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown server subcommand: #{unknown}", usage_hint())
    end
  end

  # `arb server migrate` — run migrations standalone (the deploy step in
  # isolation). Resolves the project root the same way `arb server deploy` does.
  defp migrate(argv) do
    if "--help" in argv or "-h" in argv do
      IO.puts("Run Arbiter's database migrations explicitly, outside the boot process.")
    else
      mode = Output.mode(argv)

      root =
        case Cmd.Start.project_root() do
          {:ok, dir} ->
            dir

          :error ->
            Output.die(
              "could not locate the Arbiter project root (no compose.yml found)",
              "Set ARB_HOME to your Arbiter checkout, or run `arb server migrate` from inside it."
            )
        end

      case Cmd.Migrate.run(root) do
        {:ok, count} -> emit_migrate(count, mode)
        {:error, err} -> Output.die("Database migration failed", err)
      end
    end
  end

  defp emit_migrate(count, :json) do
    IO.puts(Jason.encode!(%{migrations_applied: count, status: "ok"}))
  end

  defp emit_migrate(0, :text),
    do: IO.puts("Database schema already current (no migrations to apply).")

  defp emit_migrate(count, :text), do: IO.puts("Applied #{count} migration(s).")

  defp usage_hint do
    "verbs: start, restart, deploy, migrate, doctor, version"
  end
end
