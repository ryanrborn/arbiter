defmodule ArbiterCli.Cmd.Server do
  @moduledoc """
  `arb server <verb>` — manage the Arbiter server stack (SQLite + Phoenix).

      arb server start    [--timeout SECONDS] [--json]
      arb server restart  [--timeout SECONDS] [--json]
      arb server deploy   [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]
                          deploy from a GitHub Release: download + verify
                          arbiter-<v>-linux.tar.gz → migrate → atomically swap
                          the current symlink → restart → health-check, with
                          auto-rollback on failure.
      arb server deploy --git-pull [--timeout SECONDS] [--json] [--force]
                          dev-runtime path: git pull --ff-only main → migrate →
                          rebuild CLI if changed → restart Phoenix.
                          Use this after a `git pull` that brought in new
                          migrations; it applies them and reloads the server in
                          one step.
      arb server migrate  [--timeout SECONDS] [--json] [--force]
                          apply pending database migrations.
                          When the server is running: restarts it so
                          Boot.Migrator can apply migrations as a synchronous
                          boot step — running `mix arbiter.migrate` standalone
                          races the live SQLite writer and fails with
                          queue_timeout. Pass --force to bypass the active-
                          worker guard.
                          When the server is down: runs migrations standalone
                          (safe — no competing connection).
      arb server doctor   [--json]
      arb server version  [--json]

  ## Dev-runtime deploy runbook

  After a `git pull` that includes new migrations, the dev Phoenix server
  hot-reloads the new code but NOT the schema. The next request hits
  `Phoenix.Ecto.CheckRepoStatus`, which raises `PendingMigrationError` and
  500s every request until the migration is applied.

  **Correct fix:**

      arb server deploy --git-pull   # pull → migrate → restart (one step)

  or, if you already pulled manually:

      arb server migrate             # restart (applies migrations via Boot.Migrator)
      # — or —
      arb restart                    # same effect; Boot.Migrator runs on every boot

  **Do NOT run `arb server migrate` while the server is live** without the
  restart path — `mix arbiter.migrate` competes for the single SQLite writer
  connection and fails with `queue_timeout`. `arb server migrate` now detects
  a running server and redirects to restart automatically.
  """

  alias ArbiterCli.{Cmd, Cmd.Doctor, Cmd.Restart, Cmd.Start, Output}

  @migrate_switches [json: :boolean, timeout: :integer, force: :boolean]
  @default_migrate_timeout_s 60

  def run(argv) do
    case argv do
      ["start" | rest] -> Cmd.Start.run(rest)
      ["restart" | rest] -> Cmd.Restart.run(rest)
      ["deploy" | rest] -> deploy(rest)
      ["migrate" | rest] -> migrate(rest)
      ["doctor" | rest] -> Cmd.Doctor.run(rest)
      ["version" | rest] -> Cmd.Version.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("server requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown server subcommand: #{unknown}", usage_hint())
    end
  end

  # `arb server deploy` — deploy from a GitHub Release (the new default). The
  # legacy git-pull deploy is preserved behind `--git-pull` until the cutover
  # to release-based deploys is complete.
  defp deploy(argv) do
    if "--git-pull" in argv do
      Cmd.Update.deploy(argv -- ["--git-pull"])
    else
      Cmd.ReleaseDeploy.run(argv)
    end
  end

  # `arb server migrate` — apply pending migrations.
  #
  # When the server is running, a standalone `mix arbiter.migrate` races the live
  # server for the single SQLite writer connection and fails with queue_timeout.
  # The safe path is to restart: Boot.Migrator runs pending migrations
  # synchronously as the first supervised child, before the endpoint opens, so
  # every restart is also a migration run. We detect the running server here and
  # redirect to restart rather than silently failing with a confusing DB error.
  #
  # When the server is down there is no competing connection, so we run
  # migrations standalone (the original behaviour).
  defp migrate(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @migrate_switches)
      mode = Output.mode(argv)
      timeout_ms = max(1, opts[:timeout] || @default_migrate_timeout_s) * 1000
      force = opts[:force] || false

      root =
        case Start.project_root() do
          {:ok, dir} ->
            dir

          :error ->
            Output.die(
              "could not locate the Arbiter project root (no compose.yml found)",
              "Set ARB_HOME to your Arbiter checkout, or run `arb server migrate` from inside it."
            )
        end

      if Doctor.reachable?() do
        # Server is up — restart it so Boot.Migrator applies pending migrations.
        Start.log_text(
          "Server is running. Restarting to apply pending migrations " <>
            "(Boot.Migrator runs on every boot)…"
        )

        Restart.guard_acolyte_session!()
        Restart.guard_active_workers!(force)

        case Restart.perform(root, timeout_ms) do
          {:ok, _actions, _was_running} ->
            emit_migrate_via_restart(mode)

          {:timeout, _actions, _was_running} ->
            Output.die(
              "Server did not come back up within #{div(timeout_ms, 1000)}s",
              "hint: tail #{Start.phoenix_log_path()} for Phoenix startup output."
            )
        end
      else
        # Server is down — safe to run standalone migrations.
        case Cmd.Migrate.run(root) do
          {:ok, count} -> emit_migrate(count, mode)
          {:error, err} -> Output.die("Database migration failed", err)
        end
      end
    end
  end

  defp emit_migrate_via_restart(:json) do
    IO.puts(Jason.encode!(%{restarted: true, status: "ok"}))
  end

  defp emit_migrate_via_restart(:text) do
    IO.puts("Server restarted. Boot.Migrator applied any pending migrations on boot.")
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
