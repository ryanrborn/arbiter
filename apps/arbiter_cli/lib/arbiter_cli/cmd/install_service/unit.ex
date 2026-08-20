defmodule ArbiterCli.Cmd.InstallService.Unit do
  @moduledoc """
  Builds and writes the `arbiter.service` systemd unit content for
  `arb install-service`, and the `.run-server.sh` launcher a dev-mode
  checkout's unit execs into.
  """

  alias ArbiterCli.Output

  @run_server_script_name ".run-server.sh"

  @unit_name "arbiter.service"
  @logrotate_timer_name "arbiter-logrotate.timer"

  @doc "The systemd unit file name, shared across install/uninstall/status/logs."
  @spec unit_name() :: String.t()
  def unit_name, do: @unit_name

  @doc "The logrotate timer unit name."
  @spec logrotate_timer_name() :: String.t()
  def logrotate_timer_name, do: @logrotate_timer_name

  @doc """
  The arbiter data home directory. Defaults to `~/.arbiter`; tests override
  via the `:bd2_arbiter_home` process-dict seam so they write to a tmp dir
  rather than the real `~/.arbiter/arbiter.env`.
  """
  @spec arbiter_home_path() :: String.t()
  def arbiter_home_path do
    case Process.get(:bd2_arbiter_home) do
      dir when is_binary(dir) -> dir
      _ -> Path.join(System.user_home!(), ".arbiter")
    end
  end

  @doc """
  The systemd unit file content for `scope`. Pure (given the environment and
  filesystem) so it's easy to assert on in tests.

  Dispatches on whether `root` is a dev-mode source checkout
  (`dev_checkout?/1` — mirrors `Cmd.Start.is_umbrella_root?/1`'s mix.exs +
  apps/ heuristic):

    * **not a checkout (release install)** — `ExecStart` points at the OTP
      release binary under `arbiter_home/current/bin/arbiter`.
    * **a checkout (dev mode)** — `ExecStart` instead runs
      `root/.run-server.sh`, so systemd tracks the real BEAM process started
      via `mix phx.server` rather than a detached background job.

  The dispatch depends only on `root`'s filesystem shape, so re-running with
  the same root always produces the same unit shape — it never flip-flops
  between modes.
  """
  @spec unit_contents(:user | :system, String.t(), String.t()) :: String.t()
  def unit_contents(scope, arbiter_home, root) do
    if dev_checkout?(root) do
      dev_unit_contents(scope, arbiter_home, root)
    else
      release_unit_contents(scope, arbiter_home)
    end
  end

  # Deliberately NOT `Start.is_umbrella_root?/1` — that helper also treats a
  # bare `compose.yml` (no mix.exs/apps/) as a root, which is right for
  # locating *some* Arbiter home but wrong here: a release-install box whose
  # ARB_HOME points at a data dir holding only the Postgres compose.yml would
  # get misclassified as dev mode and lose its release unit. This checks
  # mix.exs + apps/ directly, so a compose-only root is release mode.
  @spec dev_checkout?(String.t()) :: boolean()
  def dev_checkout?(root) do
    File.exists?(Path.join(root, "mix.exs")) and File.dir?(Path.join(root, "apps"))
  end

  defp release_unit_contents(scope, arbiter_home) do
    release_bin = Path.join([arbiter_home, "current", "bin", "arbiter"])
    wanted_by = if scope == :system, do: "multi-user.target", else: "default.target"
    ordering = unit_ordering(scope)
    log_directives = unit_log_directives(scope, arbiter_home)

    """
    [Unit]
    Description=Arbiter stack (Postgres + Phoenix)
    Documentation=https://github.com/ryanrborn/arbiter
    #{ordering}
    [Service]
    Type=exec
    WorkingDirectory=#{arbiter_home}
    EnvironmentFile=-#{Path.join(arbiter_home, "arbiter.env")}
    #{release_environment_lines()}
    #{log_directives}ExecStart=#{release_bin} start
    Restart=on-failure
    RestartSec=10

    [Install]
    WantedBy=#{wanted_by}
    """
  end

  # Dev-mode unit: same shape as the release unit (Type=exec, EnvironmentFile
  # still `arbiter_home/arbiter.env` so captured secrets/PATH keep working
  # unchanged), but ExecStart runs the source checkout via `.run-server.sh`
  # instead of the release binary, WorkingDirectory is the checkout root (not
  # arbiter_home), and ARB_HOME is forwarded so any subprocess resolves the
  # same checkout. TimeoutStartSec is raised as a generous, mostly-harmless
  # safety margin — under `Type=exec`, systemd marks the unit started as soon
  # as `/bin/sh` execs, before `mix phx.server` even runs, so this directive
  # does NOT actually span `mix`'s cold-compile time (unlike, say, `Type=notify`
  # would need).
  defp dev_unit_contents(scope, arbiter_home, root) do
    run_server_sh = Path.join(root, @run_server_script_name)
    wanted_by = if scope == :system, do: "multi-user.target", else: "default.target"
    ordering = unit_ordering(scope)
    log_directives = unit_log_directives(scope, arbiter_home)

    """
    [Unit]
    Description=Arbiter stack (Postgres + Phoenix) [dev-mode source checkout]
    Documentation=https://github.com/ryanrborn/arbiter
    #{ordering}
    [Service]
    Type=exec
    WorkingDirectory=#{root}
    EnvironmentFile=-#{Path.join(arbiter_home, "arbiter.env")}
    Environment=ARB_HOME=#{root}
    #{release_environment_lines()}
    #{log_directives}ExecStart=/bin/sh #{run_server_sh}
    Restart=on-failure
    RestartSec=10
    TimeoutStartSec=900

    [Install]
    WantedBy=#{wanted_by}
    """
  end

  # System units can order against the docker daemon; a user manager runs in
  # a different bus and can't.
  defp unit_ordering(:system),
    do: "After=network-online.target docker.service\nWants=network-online.target\n"

  defp unit_ordering(:user), do: ""

  # User installs write to a persistent file so logs survive reboots and are
  # readable without sudo or systemd-journal membership. System installs keep
  # journald (they have root and /var/log/journal is typically persistent).
  defp unit_log_directives(:user, arbiter_home) do
    log_file = Path.join([arbiter_home, "log", "arbiter.log"])
    "StandardOutput=append:#{log_file}\nStandardError=append:#{log_file}\n"
  end

  defp unit_log_directives(:system, _arbiter_home), do: ""

  @doc """
  Generate `.run-server.sh` at the checkout root if it isn't already there.
  Never overwrites an existing script — a hand-tuned launcher (or one this
  command generated on a prior run) is left alone.

  This script is consumed by more than systemd: `Cmd.Start.start_phoenix/1`
  prefers `root/.run-server.sh` whenever it exists, falling back to an
  inline launcher otherwise. So it must stand on its own as a valid
  launcher for `arb start`/`arb restart` too, not just as an `ExecStart=`
  target — including sourcing `.arbiter.env` itself (see below).
  """
  @spec ensure_run_server_script(String.t()) :: :ok
  def ensure_run_server_script(root) do
    path = Path.join(root, @run_server_script_name)
    unless File.exists?(path), do: write_run_server_script(path, root)
    :ok
  end

  defp write_run_server_script(path, root) do
    File.write!(path, run_server_script_contents())
    File.chmod!(path, 0o755)
  rescue
    e in File.Error ->
      Output.die(
        "could not write #{path}: #{:file.format_error(e.reason)}",
        "Check the checkout root is writable: #{root}"
      )
  end

  # `EnvironmentFile=` covers the captured secrets/PATH (see EnvFile) when run
  # under systemd, but not the checkout's own `.arbiter.env` (holds
  # SECRET_KEY_BASE, DATABASE_PATH, ARBITER_CLOAK_KEY — see .gitignore) — and
  # this script also runs standalone from `arb start` with no EnvironmentFile
  # at all. So it sources `.arbiter.env` itself, same as the hand-written
  # launcher it's modeled on. Every hop uses `exec` (process-image
  # replacement, not fork) so the PID systemd tracks becomes, via mix's own
  # launcher doing the same, the actual BEAM VM PID.
  defp run_server_script_contents do
    """
    #!/bin/sh
    set -e
    cd "$(dirname "$0")"
    if [ -f .arbiter.env ]; then
      set -a
      . ./.arbiter.env
      set +a
    fi
    exec mix phx.server
    """
  end

  # Optional `Environment=` pass-throughs. The OTP release is self-contained
  # (no MIX_HOME or PATH needed). ARB_HOST and ARB_WORKSPACE are forwarded
  # when set so the running node picks up the same coordinator and workspace as
  # the installing shell; secrets live in the EnvironmentFile instead.
  defp release_environment_lines do
    [
      {"ARB_HOST", System.get_env("ARB_HOST")},
      {"ARB_WORKSPACE", System.get_env("ARB_WORKSPACE")}
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.map_join("\n", fn {k, v} -> "Environment=#{k}=#{v}" end)
  end

  @spec write_unit(String.t(), String.t()) :: :ok
  def write_unit(path, contents) do
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

  @spec remove_unit(String.t()) :: boolean()
  def remove_unit(path) do
    case File.rm(path) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, reason} -> Output.die("could not remove #{path}: #{:file.format_error(reason)}")
    end
  end
end
