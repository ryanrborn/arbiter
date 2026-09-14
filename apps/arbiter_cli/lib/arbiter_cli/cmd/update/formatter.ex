defmodule ArbiterCli.Cmd.Update.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb update`'s deploy-mode outcomes: already up to
  date, deployed, and restart timeout.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Start, Output}

  def emit_up_to_date(:json, integration_branch) do
    Output.emit_json(%{
      branch: integration_branch,
      pulled: false,
      up_to_date: true,
      restarted: false,
      commits: [],
      ok: true
    })
  end

  def emit_up_to_date(:text, integration_branch) do
    IO.puts("Already up to date on #{integration_branch} — nothing to deploy.")
    IO.puts("(Run `arb restart` if you want to bounce Phoenix anyway.)")
  end

  @doc """
  Renders a completed deploy.

  The outcome travels as a single `deploy` map rather than eight positional
  arguments: at arity 9 the call sites were an unlabelled column of shas,
  counters and booleans that only a reader with the definition open could
  decode (and `mix credo --strict` flagged, correctly, as past its arity
  ceiling). Keys: `:branch`, `:before_sha`, `:after_sha`, `:commits`,
  `:actions`, `:was_running`, `:migrations_applied`, `:cli_built`.
  """
  def emit_deployed(:json, deploy) do
    %{
      branch: integration_branch,
      before_sha: before_sha,
      after_sha: after_sha,
      commits: commits,
      actions: actions,
      was_running: was_running,
      migrations_applied: migrations_applied,
      cli_built: cli_built
    } = deploy

    %{
      branch: integration_branch,
      pulled: true,
      up_to_date: false,
      restarted: true,
      was_running: was_running,
      old_sha: before_sha,
      new_sha: after_sha,
      commits: commits,
      actions: action_payload(actions),
      cli_rebuilt: cli_built,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: Doctor.green?()
    }
    |> Map.merge(migrations_payload(migrations_applied))
    |> Output.emit_json()
  end

  def emit_deployed(:text, deploy) do
    %{
      branch: integration_branch,
      commits: commits,
      migrations_applied: migrations_applied,
      cli_built: cli_built
    } = deploy

    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{integration_branch}:")
    print_commits(commits)
    IO.puts("")

    print_migrations(migrations_applied)

    if cli_built do
      IO.puts("Rebuilt and installed CLI escript")
    end

    IO.puts("")
    IO.puts("Arbiter Phoenix restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  @doc """
  Renders a deploy whose Phoenix restart never came back up.

  Same single-map argument as `emit_deployed/2`, with `:timeout_ms` in place
  of `:was_running`.
  """
  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec emit_deploy_timeout(:json | :text, map()) :: no_return()
  def emit_deploy_timeout(:json, deploy) do
    %{
      branch: integration_branch,
      before_sha: before_sha,
      after_sha: after_sha,
      commits: commits,
      actions: actions,
      timeout_ms: timeout_ms,
      migrations_applied: migrations_applied,
      cli_built: cli_built
    } = deploy

    %{
      branch: integration_branch,
      pulled: true,
      up_to_date: false,
      restarted: false,
      old_sha: before_sha,
      new_sha: after_sha,
      commits: commits,
      actions: action_payload(actions),
      cli_rebuilt: cli_built,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false,
      timed_out_after_s: div(timeout_ms, 1000)
    }
    |> Map.merge(migrations_payload(migrations_applied))
    |> Output.emit_json()

    Output.halt(1)
  end

  def emit_deploy_timeout(:text, deploy) do
    %{
      branch: integration_branch,
      commits: commits,
      timeout_ms: timeout_ms,
      migrations_applied: migrations_applied,
      cli_built: cli_built
    } = deploy

    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{integration_branch}:")
    print_commits(commits)
    IO.puts("")

    print_migrations(migrations_applied)

    if cli_built do
      IO.puts("Rebuilt and installed CLI escript")
    end

    IO.puts("")
    IO.puts("…but Phoenix did not come back up within #{div(timeout_ms, 1000)}s.")
    IO.puts("Last status:")
    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for Phoenix startup output.")
    Output.halt(1)
  end

  # `migrations_applied` is a count when `arb update` migrated the database
  # itself (server was down), or `:on_boot` when it deliberately left the work
  # to the restart's `Boot.Migrator` because the old server still held the
  # single SQLite writer (bd-bksulf).
  defp print_migrations(:on_boot),
    do:
      IO.puts(
        "Migrations applied by the restart (Boot.Migrator runs on boot, " <>
          "before the endpoint opens)"
      )

  defp print_migrations(0),
    do: IO.puts("Database schema already current (no migrations to apply)")

  defp print_migrations(count), do: IO.puts("Applied #{count} migration(s)")

  defp migrations_payload(:on_boot),
    do: %{migrations_applied: nil, migrations_applied_on_boot: true}

  defp migrations_payload(count),
    do: %{migrations_applied: count, migrations_applied_on_boot: false}

  defp print_commits(commits) do
    Enum.each(commits, fn %{sha: sha, subject: subject} ->
      IO.puts("  #{sha}  #{subject}")
    end)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end
end
