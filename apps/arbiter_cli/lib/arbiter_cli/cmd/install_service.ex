defmodule ArbiterCli.Cmd.InstallService do
  @moduledoc """
  `arb install-service [--system] [--uninstall] [--json]` — install a systemd
  unit so the Arbiter stack comes up automatically at machine boot via the OTP
  release binary.

  The unit's `ExecStart` is `~/.arbiter/current/bin/arbiter start` — the
  self-contained OTP release. The service runs as a long-lived foreground
  process (`Type=exec`), tracked by systemd for the full lifetime of the VM.

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

  The unit references `EnvironmentFile=~/.arbiter/arbiter.env` (created and
  managed by this command) for secrets and optional overrides. The OTP release
  is self-contained, so `PATH`, `MIX_HOME`, and similar mix-era env vars are
  not needed in the unit. `ARB_HOST` and `ARB_WORKSPACE`, when set in the
  installing shell, are forwarded as `Environment=` lines.

  ## Secret capture

  A boot-time service starts with no interactive shell, so the API keys you
  normally export (`GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, …) are
  not visible to it. To bridge that gap, install captures any of those keys that
  are set in the *installing* shell and writes them to `~/.arbiter/arbiter.env`
  (the same file `EnvironmentFile=` points at). Existing entries are preserved —
  a managed key already present is updated in place, sibling keys and comments
  are left untouched — and the file is locked to `0600` since it holds secrets.

  ## Idempotent

  Re-running rewrites the unit and reloads the daemon, so it's safe to run
  twice — handy after upgrading the release.

  ## Teardown

  `--uninstall` reverses everything: `disable --now` the unit, remove the file,
  and reload the daemon. Linger is left alone (other user services may rely on
  it); the printed notes mention how to drop it.

  ## Exit codes

    * `0` — installed (or uninstalled) successfully.
    * `1` — a prerequisite was missing (project root, `systemctl`), or a
      `systemctl`/`loginctl` step failed.
  """

  alias ArbiterCli.{Client, Cmd.Restart, Cmd.Start, Output}

  @switches [system: :boolean, uninstall: :boolean, json: :boolean, force: :boolean]

  @unit_name "arbiter.service"

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      scope = if opts[:system], do: :system, else: :user
      force = opts[:force] || false

      if opts[:uninstall] do
        uninstall(scope, mode)
      else
        Restart.guard_acolyte_session!()
        Restart.guard_active_workers!(force)
        install(scope, mode)
      end
    end
  end

  # ---- install -----------------------------------------------------------

  defp install(scope, mode) do
    root = resolve_root()
    # Persist the root so `arb start/restart/update` resolve it from any cwd.
    Start.record_home(root)
    arbiter_home = Path.join(System.user_home!(), ".arbiter")
    path = unit_path(scope)
    contents = unit_contents(scope, arbiter_home)

    secrets = capture_secrets(arbiter_home)

    write_unit(path, contents)
    daemon_reload(scope)
    enable_now(scope)
    linger = if scope == :user, do: enable_linger(), else: :not_applicable

    emit_installed(mode, scope, path, arbiter_home, linger, secrets)
  end

  # ---- secret capture ----------------------------------------------------

  # Keys forwarded from the installing shell into `.arbiter.env` so the
  # detached, login-less service can still reach GitHub and the model
  # providers. Only keys actually set (and non-empty) in the current
  # environment are written.
  @captured_secrets ~w(
    GITHUB_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_API_KEY_2
    GEMINI_API_KEY
    GOOGLE_GENAI_API_KEY
  )

  @doc """
  Forward any of `@captured_secrets` set in the current environment into
  `<arbiter_home>/arbiter.env`, preserving any keys already present. Returns
  `{:written, path, keys}` listing the keys captured, or `{:none, path}` when
  the environment carries none of them.
  """
  @spec capture_secrets(String.t()) ::
          {:written, String.t(), [String.t()]} | {:none, String.t()}
  def capture_secrets(arbiter_home) do
    path = Path.join(arbiter_home, "arbiter.env")

    captured =
      Enum.flat_map(@captured_secrets, fn key ->
        case System.get_env(key) do
          v when is_binary(v) and v != "" -> [{key, v}]
          _ -> []
        end
      end)

    case captured do
      [] ->
        {:none, path}

      pairs ->
        merged = path |> read_env_entries() |> merge_env_entries(pairs)
        write_env_file(path, render_env_entries(merged))
        {:written, path, Enum.map(pairs, &elem(&1, 0))}
    end
  end

  # Read `.arbiter.env` into an ordered list of entries: `{:kv, key, value}`
  # for `KEY=value` lines and `{:raw, line}` for everything else (comments,
  # blanks). Keeping the raw lines lets us round-trip the file without
  # clobbering the user's own keys or formatting. Missing file → empty.
  defp read_env_entries(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.map(&classify_env_line/1)
        |> drop_trailing_blanks()

      {:error, _} ->
        []
    end
  end

  defp classify_env_line(line) do
    case Regex.run(~r/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/, line) do
      [_, key, value] -> {:kv, key, value}
      _ -> {:raw, line}
    end
  end

  defp drop_trailing_blanks(entries) do
    entries
    |> Enum.reverse()
    |> Enum.drop_while(&match?({:raw, ""}, &1))
    |> Enum.reverse()
  end

  # Update managed keys in place where they already appear; append the rest.
  # Sibling keys (and comments) ride along untouched.
  defp merge_env_entries(entries, pairs) do
    updates = Map.new(pairs)

    {rewritten, seen} =
      Enum.map_reduce(entries, MapSet.new(), fn
        {:kv, key, value}, seen ->
          case Map.fetch(updates, key) do
            {:ok, new_value} -> {{:kv, key, new_value}, MapSet.put(seen, key)}
            :error -> {{:kv, key, value}, seen}
          end

        other, seen ->
          {other, seen}
      end)

    appended =
      pairs
      |> Enum.reject(fn {k, _v} -> MapSet.member?(seen, k) end)
      |> Enum.map(fn {k, v} -> {:kv, k, v} end)

    rewritten ++ appended
  end

  defp render_env_entries(entries) do
    body =
      Enum.map_join(entries, "\n", fn
        {:kv, key, value} -> "#{key}=#{value}"
        {:raw, line} -> line
      end)

    body <> "\n"
  end

  # `.arbiter.env` holds secrets, so it's written 0600 (owner read/write only)
  # on every write — both at creation and when tightening an existing file.
  defp write_env_file(path, body) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, body)
    File.chmod!(path, 0o600)
  rescue
    e in File.Error ->
      Output.die(
        "could not write secrets to #{path}: #{:file.format_error(e.reason)}",
        "Check the destination is writable: #{Path.dirname(path)}"
      )
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
  The systemd unit file content for `scope`, pointing `ExecStart` at the OTP
  release binary under `arbiter_home/current/bin/arbiter`. Pure (given the
  environment) so it's easy to assert on in tests.
  """
  @spec unit_contents(:user | :system, String.t()) :: String.t()
  def unit_contents(scope, arbiter_home) do
    release_bin = Path.join([arbiter_home, "current", "bin", "arbiter"])
    wanted_by = if scope == :system, do: "multi-user.target", else: "default.target"

    # System units can order against the docker daemon; a user manager runs in
    # a different bus and can't.
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
    Type=exec
    WorkingDirectory=#{arbiter_home}
    EnvironmentFile=-#{Path.join(arbiter_home, "arbiter.env")}
    #{release_environment_lines()}
    ExecStart=#{release_bin} start
    Restart=on-failure
    RestartSec=10

    [Install]
    WantedBy=#{wanted_by}
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

  # ---- output ------------------------------------------------------------

  defp emit_installed(:json, scope, path, root, linger, secrets) do
    {env_path, captured} =
      case secrets do
        {:written, p, keys} -> {p, keys}
        {:none, p} -> {p, []}
      end

    IO.puts(
      Jason.encode!(%{
        action: "install",
        scope: to_string(scope),
        unit: @unit_name,
        unit_path: path,
        root: root,
        linger: to_string(linger),
        env_file: env_path,
        secrets_captured: captured,
        status_cmd: status_cmd(scope),
        logs_cmd: logs_cmd(scope),
        base_url: Client.base_url(),
        ok: true
      })
    )
  end

  defp emit_installed(:text, scope, path, _root, linger, secrets) do
    IO.puts("Installed #{@unit_name} (#{scope} scope).")
    IO.puts("  unit:   #{path}")
    IO.puts("  starts: #{Client.base_url()} at boot")
    IO.puts(secrets_note(secrets))
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

  # Scope-aware inspection commands echoed in the success output.
  defp status_cmd(:user), do: "systemctl --user status #{@unit_name}"
  defp status_cmd(:system), do: "systemctl status #{@unit_name}"
  defp logs_cmd(:user), do: "journalctl --user -u #{@unit_name} -f"
  defp logs_cmd(:system), do: "journalctl -u #{@unit_name} -f"
end
