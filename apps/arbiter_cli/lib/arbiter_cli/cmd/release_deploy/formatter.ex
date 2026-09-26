defmodule ArbiterCli.Cmd.ReleaseDeploy.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb server deploy` outcomes: already-current,
  deployed, timed-out rollback, and post-restart version-mismatch rollback.
  """

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.ReleaseDeploy.ReleaseFiles, Cmd.Start, Output}

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

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec emit_rollback(:json | :text, String.t(), rollback_outcome(), non_neg_integer(), list()) ::
          no_return()
  def emit_rollback(:json, tag, outcome, timeout_ms, pre_deploy_fails) do
    %{
      version: tag,
      deployed: false,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false,
      timed_out_after_s: div(timeout_ms, 1000),
      pre_existing_blocking_failures: pre_deploy_fails
    }
    |> Map.merge(rollback_payload(outcome))
    |> Output.emit_json()

    Output.halt(1)
  end

  def emit_rollback(:text, tag, outcome, timeout_ms, pre_deploy_fails) do
    IO.puts("")
    IO.puts("Release #{tag} did not come back green within #{div(timeout_ms, 1000)}s.")
    IO.puts(rollback_text(outcome, tag, :green_timeout))

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

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec emit_swap_failed(:json | :text, String.t(), String.t() | nil, rollback_outcome()) ::
          no_return()
  def emit_swap_failed(:json, tag, server_vsn, outcome) do
    %{
      version: tag,
      deployed: false,
      server_version_after_restart: server_vsn,
      base_url: Client.base_url(),
      checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
      ok: false
    }
    |> Map.merge(rollback_payload(outcome))
    |> Output.emit_json()

    Output.halt(1)
  end

  def emit_swap_failed(:text, tag, server_vsn, outcome) do
    IO.puts("")

    IO.puts(
      "Deploy of #{tag} restarted the service, but /api/version still reports " <>
        "#{server_vsn} — the swap did not take."
    )

    IO.puts(rollback_text(outcome, tag, :version_mismatch))

    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for startup output.")
    Output.halt(1)
  end

  # ---- cold deploy: server was already down before the deploy began -------
  #
  # bd-5zvux5: reached only when the pre-restart `Doctor.reachable?()` sample
  # was already false, so there was nothing healthy to protect with a
  # rollback — this covers a first-ever bootstrap deploy (no `current` yet)
  # and a planned-downtime deploy (e.g. a DB move) alike. Unlike
  # `emit_rollback/5`, this never attempts a rollback and never frames a still
  # -red doctor result as this deploy's fault; it reports the new release's
  # own doctor outcome as-is.
  def emit_cold_deploy(:json, tag, actions, timeout_ms, pre_deploy_fails) do
    results = Doctor.checks()
    ok = Doctor.green?(results)

    Output.emit_json(%{
      version: tag,
      deployed: true,
      already_current: false,
      rolled_back: false,
      cold_deploy: true,
      was_running: false,
      actions: action_payload(actions),
      base_url: Client.base_url(),
      checks: Enum.map(results, &Map.from_struct/1),
      ok: ok,
      timed_out_after_s: div(timeout_ms, 1000),
      pre_existing_blocking_failures: pre_deploy_fails
    })

    unless ok, do: Output.halt(1)
  end

  def emit_cold_deploy(:text, tag, _actions, timeout_ms, pre_deploy_fails) do
    IO.puts("")

    IO.puts(
      "Deployed release #{tag} — the server was already down before this deploy began, so " <>
        "there was nothing healthy to roll back to. Not attempting a rollback."
    )

    if pre_deploy_fails != [] do
      IO.puts("(pre-existing, before this deploy: #{Enum.join(pre_deploy_fails, ", ")})")
    end

    IO.puts("")

    IO.puts(
      "Doctor did not report green within #{div(timeout_ms, 1000)}s — this reflects release " <>
        "#{tag}'s own state, not a rollback failure:"
    )

    IO.puts("")
    results = Doctor.checks()
    Doctor.report(results)
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for startup output.")

    unless Doctor.green?(results), do: Output.halt(1)
  end

  # ---- rollback outcome rendering (bd-bksulf) ------------------------------

  @typedoc "What `ReleaseDeploy`'s automatic rollback actually did."
  @type rollback_outcome ::
          {:rolled_back | :refused | :undetected, String.t(), [String.t()]}
          | {:no_prior, nil, []}

  @typedoc """
  Which failure brought us here — it decides what we may claim about the
  database. `:green_timeout` means the new release booted but never went green,
  so its boot migrator did run. `:version_mismatch` means `/api/version` still
  reports the old version, i.e. the new release probably never booted at all,
  so its migrations may never have been applied (bd-bksulf review round 1).
  """
  @type failure_context :: :green_timeout | :version_mismatch

  @spec rollback_payload(rollback_outcome()) :: map()
  defp rollback_payload({:rolled_back, prior_tag, crossed}) do
    %{
      rolled_back: true,
      rolled_back_to: prior_tag,
      rollback_refused: false,
      crossed_migrations: crossed,
      migrations_detected: true
    }
  end

  defp rollback_payload({:refused, _prior_tag, crossed}) do
    %{
      rolled_back: false,
      rolled_back_to: nil,
      rollback_refused: true,
      crossed_migrations: crossed,
      migrations_detected: true
    }
  end

  # Detection itself failed: `crossed_migrations` is empty because we could not
  # read the new release's migrations, NOT because nothing crossed. Machine
  # consumers must be able to tell those apart, hence `migrations_detected`.
  defp rollback_payload({:undetected, _prior_tag, _crossed}) do
    %{
      rolled_back: false,
      rolled_back_to: nil,
      rollback_refused: true,
      crossed_migrations: [],
      migrations_detected: false
    }
  end

  defp rollback_payload({:no_prior, nil, _crossed}) do
    %{
      rolled_back: false,
      rolled_back_to: nil,
      rollback_refused: false,
      crossed_migrations: [],
      migrations_detected: true
    }
  end

  @spec rollback_text(rollback_outcome(), String.t(), failure_context()) :: String.t()
  defp rollback_text({:rolled_back, prior_tag, []}, _tag, _context) do
    "Rolled back to #{prior_tag} and restarted."
  end

  defp rollback_text({:rolled_back, prior_tag, crossed}, _tag, _context) do
    """
    Rolled back to #{prior_tag} and restarted.

    warning: this rollback crossed #{length(crossed)} migration(s) \
    (--allow-cross-migration-rollback was passed):
    #{bullets(crossed)}
    #{prior_tag} is now running against a newer schema. Verify it, and consider \
    `bin/arbiter eval "Arbiter.Release.rollback(Arbiter.Repo, <version>)"` to step the \
    schema back down.\
    """
  end

  defp rollback_text({:refused, prior_tag, crossed}, tag, context) do
    """
    Refused to roll back to #{prior_tag}: release #{tag} added #{length(crossed)} \
    migration(s) that #{prior_tag} does not ship#{applied_clause(context, tag)}:
    #{bullets(crossed)}
    Rolling back now risks running #{prior_tag}'s code against a schema it has never seen, \
    so `current` has been left pointing at #{tag}.

    Your options:
      * fix forward — deploy a newer release (`arb server deploy`); or
      * roll the schema back first with \
    `bin/arbiter eval "Arbiter.Release.rollback(Arbiter.Repo, <version>)"`, then \
    `arb server deploy --version #{prior_tag} --force`; or
      * accept a mixed-schema rollback: re-run this deploy with \
    --allow-cross-migration-rollback.\
    """
  end

  defp rollback_text({:undetected, prior_tag, _crossed}, tag, _context) do
    """
    Refused to roll back to #{prior_tag}: no migrations could be found in release #{tag} \
    (looked under #{Enum.join(ReleaseFiles.migration_globs(), " and ")}), so this deploy \
    cannot be shown to be migration-free. An arbiter release always ships migrations — an \
    empty set means the packaging layout moved and the cross-migration check is blind, not \
    that there is nothing to strand.

    `current` has been left pointing at #{tag}.

    Your options:
      * fix forward — deploy a newer release (`arb server deploy`); or
      * compare the two releases' priv/repo/migrations by hand, then roll back \
    explicitly with `arb server deploy --version #{prior_tag} --force`; or
      * accept the risk: re-run this deploy with --allow-cross-migration-rollback.\
    """
  end

  defp rollback_text({:no_prior, nil, _crossed}, _tag, _context) do
    "No prior release to roll back to — the stack is down."
  end

  # What we may honestly say about whether the crossed migrations ran. On a
  # green-wait timeout the new release booted (Boot.Migrator runs before the
  # endpoint opens), so they did. On a version mismatch the new release never
  # took, so they probably did not — refuse anyway, but don't assert a fact we
  # cannot see from here.
  @spec applied_clause(failure_context(), String.t()) :: String.t()
  defp applied_clause(:green_timeout, tag),
    do: ", and they have already been applied to the database by #{tag}'s boot"

  defp applied_clause(:version_mismatch, tag),
    do:
      ". The swap did not take, so whether #{tag}'s boot applied them cannot be " <>
        "determined from here — check the schema before assuming either way"

  defp bullets(items), do: Enum.map_join(items, "\n", &("  - " <> &1))

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end
end
