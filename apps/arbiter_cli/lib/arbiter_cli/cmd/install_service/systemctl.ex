defmodule ArbiterCli.Cmd.InstallService.Systemctl do
  @moduledoc """
  `systemctl`/`loginctl` shelling for `arb install-service` — daemon reload,
  enable/disable, and boot-before-login linger — plus the scope-aware
  inspection commands echoed back in success/error output.
  """

  alias ArbiterCli.Cmd.InstallService.Unit
  alias ArbiterCli.Cmd.Start
  alias ArbiterCli.Output

  def daemon_reload(scope) do
    case systemctl(scope, ["daemon-reload"]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "systemctl daemon-reload failed (exit #{code})",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  def enable_now(scope) do
    Start.log_text("Enabling and starting #{Unit.unit_name()}…")

    case systemctl(scope, ["enable", "--now", Unit.unit_name()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "systemctl enable --now #{Unit.unit_name()} failed (exit #{code})",
          "Inspect it with `#{status_cmd(scope)}` and `#{logs_cmd(scope)}`. Output:\n" <>
            String.trim_trailing(out)
        )
    end
  end

  # Idempotent stop+disable. Returns whether the unit was actually disabled (a
  # non-zero exit means it wasn't installed / already disabled — not fatal).
  def disable_now(scope) do
    case systemctl(scope, ["disable", "--now", Unit.unit_name()]) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  # Boot-before-login for user services. Idempotent; non-zero is non-fatal
  # (e.g. a non-systemd-logind host) so the install still succeeds — we just
  # report that linger couldn't be enabled.
  def enable_linger do
    user = System.get_env("USER") || System.get_env("LOGNAME") || ""

    case run_cmd("loginctl", ["enable-linger" | linger_args(user)], stderr_to_stdout: true) do
      {_out, 0} -> :enabled
      {_out, _nonzero} -> :failed
    end
  rescue
    e in ErlangError ->
      # loginctl missing — surface as "couldn't enable" rather than aborting.
      _ = e
      :failed
  end

  defp linger_args(""), do: []
  defp linger_args(user), do: [user]

  def systemctl(scope, args) do
    full = if scope == :user, do: ["--user" | args], else: args

    run_cmd("systemctl", full, stderr_to_stdout: true)
  rescue
    e in ErlangError ->
      Output.die(
        "could not run systemctl: #{inspect(e.original)}",
        "Is this a systemd host? Ensure `systemctl` is on your PATH."
      )
  end

  defp run_cmd(cmd, args, opts), do: Start.run_cmd(cmd, args, opts)

  # Scope-aware inspection commands echoed in the success/error output.
  def status_cmd(:user), do: "systemctl --user status #{Unit.unit_name()}"
  def status_cmd(:system), do: "systemctl status #{Unit.unit_name()}"

  # User services write to a file (no journald permissions needed); system
  # installs have root so journalctl works directly.
  def logs_cmd(:user) do
    log_file = Path.join([Unit.arbiter_home_path(), "log", "arbiter.log"])
    "tail -f #{log_file}"
  end

  def logs_cmd(:system), do: "journalctl -u #{Unit.unit_name()} -f"
end
