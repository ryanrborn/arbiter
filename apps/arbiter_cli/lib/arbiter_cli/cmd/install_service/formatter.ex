defmodule ArbiterCli.Cmd.InstallService.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb install-service` install/uninstall results.
  """

  alias ArbiterCli.Client
  alias ArbiterCli.Cmd.InstallService.{Systemctl, Unit}
  alias ArbiterCli.Output

  def emit_installed(:json, scope, path, root, linger, secrets, log_paths) do
    {env_path, captured} =
      case secrets do
        {:written, p, keys} -> {p, keys}
        {:none, p} -> {p, []}
      end

    base = %{
      action: "install",
      scope: to_string(scope),
      unit: Unit.unit_name(),
      unit_path: path,
      root: root,
      linger: to_string(linger),
      env_file: env_path,
      secrets_captured: captured,
      status_cmd: Systemctl.status_cmd(scope),
      logs_cmd: Systemctl.logs_cmd(scope),
      base_url: Client.base_url(),
      ok: true
    }

    base =
      if log_paths do
        {config_path, state_file} = log_paths

        Map.merge(base, %{
          logrotate_timer: Unit.logrotate_timer_name(),
          logrotate_config: config_path,
          logrotate_state: state_file
        })
      else
        base
      end

    Output.emit_json(base)
  end

  def emit_installed(:text, scope, path, arbiter_home, linger, secrets, log_paths) do
    IO.puts("Installed #{Unit.unit_name()} (#{scope} scope).")
    IO.puts("  unit:   #{path}")
    IO.puts("  starts: #{Client.base_url()} at boot")
    IO.puts(secrets_note(secrets))
    IO.puts("")
    IO.puts(linger_note(scope, linger))
    IO.puts("Check it with:")
    IO.puts("  #{Systemctl.status_cmd(scope)}")
    IO.puts("  #{Systemctl.logs_cmd(scope)}")

    if log_paths do
      {config_path, state_file} = log_paths
      IO.puts("")
      IO.puts("Logs are written to #{Path.join([arbiter_home, "log", "arbiter.log"])}.")

      IO.puts(
        "A daily systemd timer (#{Unit.logrotate_timer_name()}) rotates logs automatically."
      )

      IO.puts("Rotate manually with:")
      IO.puts("  logrotate --state #{state_file} #{config_path}")
    end

    IO.puts("")

    IO.puts(
      "Remove it with `arb install-service#{if scope == :system, do: " --system", else: ""} --uninstall`."
    )
  end

  def emit_uninstalled(:json, scope, path, disabled?, removed?) do
    Output.emit_json(%{
      action: "uninstall",
      scope: to_string(scope),
      unit: Unit.unit_name(),
      unit_path: path,
      disabled: disabled?,
      removed: removed?,
      ok: true
    })
  end

  def emit_uninstalled(:text, scope, path, disabled?, removed?) do
    IO.puts("Uninstalled #{Unit.unit_name()} (#{scope} scope).")
    IO.puts("  disabled: #{if disabled?, do: "yes", else: "was not enabled"}")
    IO.puts("  removed:  #{if removed?, do: path, else: "no unit file at #{path}"}")

    if scope == :user do
      IO.puts("")
      IO.puts("Linger was left enabled; drop it with `loginctl disable-linger` if no other")
      IO.puts("user services need boot-before-login.")
    end
  end

  defp secrets_note({:written, path, keys}),
    do: "  secrets: #{Enum.join(keys, ", ")} → #{path}"

  defp secrets_note({:none, path}) do
    "  secrets: none found in the environment — set GITHUB_TOKEN (and any\n" <>
      "           ANTHROPIC_API_KEY / GEMINI_API_KEY) then re-run, or add them\n" <>
      "           to #{path} yourself."
  end

  defp linger_note(:system, _), do: "Enabled at boot via the system manager."

  defp linger_note(:user, :enabled),
    do: "Enabled boot-before-login via `loginctl enable-linger`."

  defp linger_note(:user, :failed) do
    "warning: could not enable linger automatically. The service will start at your\n" <>
      "next login. For boot-before-login, run: loginctl enable-linger #{System.get_env("USER")}"
  end
end
