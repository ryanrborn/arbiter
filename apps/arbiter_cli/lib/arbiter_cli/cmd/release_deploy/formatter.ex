defmodule ArbiterCli.Cmd.ReleaseDeploy.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb server deploy` outcomes: already-current,
  deployed, timed-out rollback, and post-restart version-mismatch rollback.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Start, Output}

  def emit_already_current(:json, tag) do
    Output.emit_json(%{
      version: tag,
      deployed: false,
      already_current: true,
      rolled_back: false,
      ok: true
    })
  end

  def emit_already_current(:text, tag) do
    IO.puts("Already on release #{tag} — nothing to deploy.")
    IO.puts("(Pass --force to redeploy the same version, or --version to pick another.)")
  end

  def emit_deployed(:json, tag, prior, actions, was_running, pruned) do
    Output.emit_json(%{
      version: tag,
      previous_version: prior,
      deployed: true,
      already_current: false,
      rolled_back: false,
      was_running: was_running,
      actions: action_payload(actions),
      pruned: pruned,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: Doctor.green?()
    })
  end

  def emit_deployed(:text, tag, prior, _actions, _was_running, pruned) do
    IO.puts("")
    IO.puts("Deployed release #{tag}" <> if(prior, do: " (was #{prior})", else: ""))

    if pruned != [] do
      IO.puts("Pruned #{length(pruned)} old release(s): #{Enum.join(pruned, ", ")}")
    end

    IO.puts("")
    IO.puts("Arbiter restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  def emit_rollback(:json, tag, rolled_back, timeout_ms, pre_deploy_fails) do
    Output.emit_json(%{
      version: tag,
      deployed: false,
      rolled_back: rolled_back != nil,
      rolled_back_to: rolled_back,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false,
      timed_out_after_s: div(timeout_ms, 1000),
      pre_existing_blocking_failures: pre_deploy_fails
    })

    Output.halt(1)
  end

  def emit_rollback(:text, tag, rolled_back, timeout_ms, pre_deploy_fails) do
    IO.puts("")
    IO.puts("Release #{tag} did not come back green within #{div(timeout_ms, 1000)}s.")

    if rolled_back do
      IO.puts("Rolled back to #{rolled_back} and restarted.")
    else
      IO.puts("No prior release to roll back to — the stack is down.")
    end

    if pre_deploy_fails != [] do
      IO.puts("")

      IO.puts(
        "note: #{Enum.join(pre_deploy_fails, ", ")} was already failing before this deploy " <>
          "started — this rollback may be due to that pre-existing condition, not release #{tag}."
      )
    end

    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for startup output.")
    Output.halt(1)
  end

  def emit_swap_failed(:json, tag, server_vsn, rolled_back) do
    Output.emit_json(%{
      version: tag,
      deployed: false,
      rolled_back: rolled_back != nil,
      rolled_back_to: rolled_back,
      server_version_after_restart: server_vsn,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false
    })

    Output.halt(1)
  end

  def emit_swap_failed(:text, tag, server_vsn, rolled_back) do
    IO.puts("")

    IO.puts(
      "Deploy of #{tag} restarted the service, but /api/version still reports " <>
        "#{server_vsn} — the swap did not take."
    )

    if rolled_back do
      IO.puts("Rolled back to #{rolled_back} and restarted.")
    else
      IO.puts("No prior release to roll back to — the stack is on an unexpected version.")
    end

    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for startup output.")
    Output.halt(1)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end
end
