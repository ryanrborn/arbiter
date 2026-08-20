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

  def emit_deployed(
        :json,
        integration_branch,
        before_sha,
        after_sha,
        commits,
        actions,
        was_running,
        migrations_applied,
        cli_built
      ) do
    Output.emit_json(%{
      branch: integration_branch,
      pulled: true,
      up_to_date: false,
      restarted: true,
      was_running: was_running,
      old_sha: before_sha,
      new_sha: after_sha,
      commits: commits,
      actions: action_payload(actions),
      migrations_applied: migrations_applied,
      cli_rebuilt: cli_built,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: Doctor.green?()
    })
  end

  def emit_deployed(
        :text,
        integration_branch,
        _before,
        _after,
        commits,
        _actions,
        _was_running,
        migrations_applied,
        cli_built
      ) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{integration_branch}:")
    print_commits(commits)
    IO.puts("")

    if migrations_applied > 0 do
      IO.puts("Applied #{migrations_applied} migration(s)")
    else
      IO.puts("Database schema already current (no migrations to apply)")
    end

    if cli_built do
      IO.puts("Rebuilt and installed CLI escript")
    end

    IO.puts("")
    IO.puts("Arbiter Phoenix restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  def emit_deploy_timeout(
        :json,
        integration_branch,
        before_sha,
        after_sha,
        commits,
        actions,
        timeout_ms,
        migrations_applied,
        cli_built
      ) do
    Output.emit_json(%{
      branch: integration_branch,
      pulled: true,
      up_to_date: false,
      restarted: false,
      old_sha: before_sha,
      new_sha: after_sha,
      commits: commits,
      actions: action_payload(actions),
      migrations_applied: migrations_applied,
      cli_rebuilt: cli_built,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false,
      timed_out_after_s: div(timeout_ms, 1000)
    })

    Output.halt(1)
  end

  def emit_deploy_timeout(
        :text,
        _integration_branch,
        _before,
        _after,
        commits,
        _actions,
        timeout_ms,
        migrations_applied,
        cli_built
      ) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s):")
    print_commits(commits)
    IO.puts("")

    if migrations_applied > 0 do
      IO.puts("Applied #{migrations_applied} migration(s)")
    else
      IO.puts("Database schema already current (no migrations to apply)")
    end

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
