defmodule ArbiterCli.Cmd.InstallService do
  @moduledoc """
  `arb install-service [--system] [--uninstall] [--json]` — install a systemd
  unit so the Arbiter stack (Postgres + Phoenix) comes up automatically at
  machine boot, with no manual `mix phx.server`.

  The unit's `ExecStart` is just `arb start` (bd-cw6rka), so there is exactly
  one definition of "bring the stack up": ensure the Postgres container, start
  Phoenix detached, and wait for the API to go green. The service is a
  `Type=oneshot` with `RemainAfterExit=yes` — once `arb start` exits 0 the unit
  is considered active, and the detached Phoenix keeps running.

  ## Scope

    * **User (default)** — written to `~/.config/systemd/user/arbiter.service`
      and managed with `systemctl --user`. Installs run without root. Because a
      user manager normally exits at logout, the command also runs
      `loginctl enable-linger` so the service starts at *boot*, before any
      login.
    * **System (`--system`)** — written to `/etc/systemd/system/arbiter.service`
      and managed with plain `systemctl`. Writing there and reloading the
      system manager need root, so run with `sudo` if you aren't already.

  ## What it writes

  The unit carries enough environment to run outside your shell:

    * `PATH` is copied from the current environment so `mix`, `docker`, and
      friends resolve.
    * `ARB_HOME` is pinned to the resolved project root (also the
      `WorkingDirectory`), with `ARB_HOST` / `ARB_WORKSPACE` forwarded when set.
    * `EnvironmentFile=-<root>/.arbiter.env` is referenced optionally (the
      leading `-` means "skip if absent") so secrets like `GITHUB_TOKEN` live in
      a file you control rather than baked into a world-readable unit.

  ## Idempotent

  Re-running rewrites the unit and reloads the daemon, so it's safe to run
  twice — handy after upgrading or moving the checkout.

  ## Teardown

  `--uninstall` reverses everything: `disable --now` the unit, remove the file,
  and reload the daemon. Linger is left alone (other user services may rely on
  it); the printed notes mention how to drop it.

  ## Exit codes

    * `0` — installed (or uninstalled) successfully.
    * `1` — a prerequisite was missing (project root, `systemctl`), or a
      `systemctl`/`loginctl` step failed.
  """

  alias ArbiterCli.{Client, Cmd.Start, Output}

  @switches [system: :boolean, uninstall: :boolean, json: :boolean]

  @unit_name "arbiter.service"

  # How long the service is allowed to spend coming up before systemd calls the
  # start a failure. Generous: a cold `mix phx.server` may compile first. The
  # inner `arb start --timeout` is set a touch lower so it reports its own
  # timeout before systemd's harder cutoff fires.
  @start_timeout_s 240
  @systemd_timeout_s 300

  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    scope = if opts[:system], do: :system, else: :user

    if opts[:uninstall] do
      uninstall(scope, mode)
    else
      install(scope, mode)
    end
  end

  # ---- install -----------------------------------------------------------

  defp install(scope, mode) do
    root = resolve_root()
    path = unit_path(scope)
    contents = unit_contents(scope, root)

    write_unit(path, contents)
    daemon_reload(scope)
    enable_now(scope)
    linger = if scope == :user, do: enable_linger(), else: :not_applicable

    emit_installed(mode, scope, path, root, linger)
  end

  # ---- uninstall ---------------------------------------------------------

  defp uninstall(scope, mode) do
    path = unit_path(scope)

    # `disable --now` both stops and de-links the unit. Tolerate a non-zero
    # exit (already disabled / never installed) so uninstall is idempotent.
    disabled? = disable_now(scope)
    removed? = remove_unit(path)
    daemon_reload(scope)

    emit_uninstalled(mode, scope, path, disabled?, removed?)
  end

  # ---- unit file ---------------------------------------------------------

  @doc """
  The systemd unit file content for `scope`, with `ExecStart` set to this
  `arb` binary's `start`. Pure (given the environment) so it's easy to assert
  on in tests.
  """
  @spec unit_contents(:user | :system, String.t()) :: String.t()
  def unit_contents(scope, root) do
    arb = arb_executable()
    wanted_by = if scope == :system, do: "multi-user.target", else: "default.target"

    # System units can order against the docker daemon; a user manager runs in
    # a different bus and can't, so it leans on `arb start`'s own
    # `docker compose up -d` (which fails loudly if the daemon isn't ready).
    ordering =
      if scope == :system do
        "After=network-online.target docker.service\nWants=network-online.target\n"
      else
        ""
      end

    """
    [Unit]
    Description=Arbiter stack (Postgres + Phoenix)
    Documentation=https://github.com/penumbral/arbiter
    #{ordering}
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    WorkingDirectory=#{root}
    EnvironmentFile=-#{Path.join(root, ".arbiter.env")}
    #{environment_lines(root)}
    ExecStart=#{arb} start --timeout #{@start_timeout_s}
    TimeoutStartSec=#{@systemd_timeout_s}

    [Install]
    WantedBy=#{wanted_by}
    """
  end

  # `Environment=` lines for the values the stack needs outside an interactive
  # shell. PATH, ARB_HOME, and MIX_HOME are always pinned; ARB_HOST /
  # ARB_WORKSPACE are forwarded only when set, so we don't freeze a stale
  # default into the unit. MIX_HOME must be present or Phoenix fails to boot
  # under systemd (Mix can't find its archives/escripts otherwise); prefer the
  # current MIX_HOME, falling back to the standard `~/.mix`.
  defp environment_lines(root) do
    mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")

    [
      {"PATH", System.get_env("PATH")},
      {"ARB_HOME", root},
      {"ARB_HOST", System.get_env("ARB_HOST")},
      {"ARB_WORKSPACE", System.get_env("ARB_WORKSPACE")},
      {"MIX_HOME", mix_home}
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.map_join("\n", fn {k, v} -> "Environment=#{k}=#{v}" end)
  end

  defp write_unit(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  rescue
    e in File.Error ->
      hint =
        if e.reason == :eacces and String.starts_with?(path, "/etc/") do
          "Writing a system unit needs root — re-run with `sudo`."
        else
          "Check the destination is writable: #{Path.dirname(path)}"
        end

      Output.die(
        "could not write the systemd unit at #{path}: #{:file.format_error(e.reason)}",
        hint
      )
  end

  defp remove_unit(path) do
    case File.rm(path) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, reason} -> Output.die("could not remove #{path}: #{:file.format_error(reason)}")
    end
  end

  # ---- systemctl / loginctl ----------------------------------------------

  defp daemon_reload(scope) do
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

  defp enable_now(scope) do
    Start.log_text("Enabling and starting #{@unit_name}…")

    case systemctl(scope, ["enable", "--now", @unit_name]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "systemctl enable --now #{@unit_name} failed (exit #{code})",
          "Inspect it with `#{status_cmd(scope)}` and `#{logs_cmd(scope)}`. Output:\n" <>
            String.trim_trailing(out)
        )
    end
  end

  # Idempotent stop+disable. Returns whether the unit was actually disabled (a
  # non-zero exit means it wasn't installed / already disabled — not fatal).
  defp disable_now(scope) do
    case systemctl(scope, ["disable", "--now", @unit_name]) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  # Boot-before-login for user services. Idempotent; non-zero is non-fatal
  # (e.g. a non-systemd-logind host) so the install still succeeds — we just
  # report that linger couldn't be enabled.
  defp enable_linger do
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

  defp systemctl(scope, args) do
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

  # ---- resolution --------------------------------------------------------

  defp resolve_root do
    case Start.project_root() do
      {:ok, dir} ->
        dir

      :error ->
        Output.die(
          "could not locate the Arbiter project root (no compose.yml found)",
          "Set ARB_HOME to your Arbiter checkout, or run `arb install-service` from inside it."
        )
    end
  end

  @doc """
  Directory the unit is written to for `scope`. Tests override via the
  `:bd2_unit_dir` process-dict seam so they can write to a tmp dir without
  touching the real systemd locations.
  """
  @spec unit_dir(:user | :system) :: String.t()
  def unit_dir(scope) do
    case Process.get(:bd2_unit_dir) do
      dir when is_binary(dir) -> dir
      _ -> default_unit_dir(scope)
    end
  end

  defp default_unit_dir(:user), do: Path.join([System.user_home!(), ".config", "systemd", "user"])
  defp default_unit_dir(:system), do: "/etc/systemd/system"

  defp unit_path(scope), do: Path.join(unit_dir(scope), @unit_name)

  # Absolute path of the running `arb` escript, baked into ExecStart so the
  # unit resolves the same binary at boot. Prefer the running escript's path
  # (when it's a real file on disk), else an `arb` found on PATH, else a bare
  # `arb` and trust the unit's own PATH. Tests pin it via `:bd2_arb_exe`.
  defp arb_executable do
    cond do
      (pinned = Process.get(:bd2_arb_exe)) && is_binary(pinned) -> pinned
      (path = escript_path()) && File.regular?(path) -> path
      path = System.find_executable("arb") -> path
      true -> "arb"
    end
  end

  defp escript_path do
    :escript.script_name() |> to_string() |> Path.expand()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ---- output ------------------------------------------------------------

  defp emit_installed(:json, scope, path, root, linger) do
    IO.puts(
      Jason.encode!(%{
        action: "install",
        scope: to_string(scope),
        unit: @unit_name,
        unit_path: path,
        root: root,
        linger: to_string(linger),
        status_cmd: status_cmd(scope),
        logs_cmd: logs_cmd(scope),
        base_url: Client.base_url(),
        ok: true
      })
    )
  end

  defp emit_installed(:text, scope, path, _root, linger) do
    IO.puts("Installed #{@unit_name} (#{scope} scope).")
    IO.puts("  unit:   #{path}")
    IO.puts("  starts: #{Client.base_url()} at boot")
    IO.puts("")
    IO.puts(linger_note(scope, linger))
    IO.puts("Check it with:")
    IO.puts("  #{status_cmd(scope)}")
    IO.puts("  #{logs_cmd(scope)}")
    IO.puts("")

    IO.puts(
      "Remove it with `arb install-service#{if scope == :system, do: " --system", else: ""} --uninstall`."
    )
  end

  defp emit_uninstalled(:json, scope, path, disabled?, removed?) do
    IO.puts(
      Jason.encode!(%{
        action: "uninstall",
        scope: to_string(scope),
        unit: @unit_name,
        unit_path: path,
        disabled: disabled?,
        removed: removed?,
        ok: true
      })
    )
  end

  defp emit_uninstalled(:text, scope, path, disabled?, removed?) do
    IO.puts("Uninstalled #{@unit_name} (#{scope} scope).")
    IO.puts("  disabled: #{if disabled?, do: "yes", else: "was not enabled"}")
    IO.puts("  removed:  #{if removed?, do: path, else: "no unit file at #{path}"}")

    if scope == :user do
      IO.puts("")
      IO.puts("Linger was left enabled; drop it with `loginctl disable-linger` if no other")
      IO.puts("user services need boot-before-login.")
    end
  end

  defp linger_note(:system, _), do: "Enabled at boot via the system manager."

  defp linger_note(:user, :enabled),
    do: "Enabled boot-before-login via `loginctl enable-linger`."

  defp linger_note(:user, :failed) do
    "warning: could not enable linger automatically. The service will start at your\n" <>
      "next login. For boot-before-login, run: loginctl enable-linger #{System.get_env("USER")}"
  end

  # Scope-aware inspection commands echoed in the success output.
  defp status_cmd(:user), do: "systemctl --user status #{@unit_name}"
  defp status_cmd(:system), do: "systemctl status #{@unit_name}"
  defp logs_cmd(:user), do: "journalctl --user -u #{@unit_name} -f"
  defp logs_cmd(:system), do: "journalctl -u #{@unit_name} -f"
end
