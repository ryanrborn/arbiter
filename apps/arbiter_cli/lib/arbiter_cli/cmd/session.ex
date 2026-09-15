defmodule ArbiterCli.Cmd.Session do
  @moduledoc """
  Coordinator-session fallback path (RFC §4.7,
  `docs/browser-hosted-coordinator-sessions.md`, bd-3qkbch phase 10):

      arb session list                       list live arb-session-* scopes
      arb session attach <id> [--read-only]  attach tmux directly (-r for read-only)

  Deliberately reads systemd and tmux **directly**, never through the Phoenix
  API — the point of this command is to work when `arbiter.service` (and
  therefore `arb`'s usual HTTP path) is down entirely. It duplicates the tiny
  bit of naming convention `Arbiter.Sessions.Naming` owns server-side
  (`arb-session-<id>.scope`, `session-<id>.sock`, tmux session `coord`)
  because this escript has no dependency on the `:arbiter` app and must not
  gain one for this — the RFC's own words: "`arb` is an escript that talks to
  the Phoenix API, so it may itself be unavailable in precisely the scenario
  this path exists for."

  `attach` hands the real terminal to `tmux` via a `:nouse_stdio` port — the
  child inherits this process's actual stdin/stdout/stderr rather than a pipe,
  which is what lets tmux's own raw-mode/SIGWINCH handling work at all. That
  path is exercised manually against a real tmux server (there is no
  meaningful way to assert full-screen terminal takeover from a headless
  test); `list` and the id-not-found/no-tmux-on-PATH branches of `attach` are
  covered by tests against a fake `systemctl` on `PATH`.
  """

  alias Arbiter.Worker.ReleaseEnv
  alias ArbiterCli.Output

  @unit_prefix "arb-session-"
  @socket_prefix "session-"
  @tmux_session "coord"

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      case Output.drop_json(argv) do
        ["list" | args] -> list(args, Output.mode(argv))
        ["attach" | args] -> attach(args)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "arb: unknown session subcommand")
    IO.puts(:stderr, "Run `arb session --help` for usage.")
    Output.halt(2)
  end

  # ---- list -----------------------------------------------------------------

  defp list(_args, mode) do
    case System.cmd(
           "systemctl",
           ["--user", "list-units", @unit_prefix <> "*", "--no-legend", "--plain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        rows = parse_units(output)
        if mode == :json, do: emit_json(rows), else: print_list(rows)

      {output, status} ->
        Output.die(
          "systemctl exited #{status}: #{String.trim(output)}",
          "Is a systemd --user manager running for this user? " <>
            "(over ssh, `loginctl enable-linger $USER` may be needed.)"
        )
    end
  rescue
    e in ErlangError ->
      Output.die(
        "could not run systemctl: #{Exception.message(e)}",
        "Is systemd installed and on PATH?"
      )
  end

  defp emit_json(rows) do
    data = Enum.map(rows, fn {id, active, sub} -> %{id: id, active: active, sub: sub} end)
    IO.puts(Jason.encode!(%{data: data}))
  end

  defp print_list(rows) do
    if rows == [] do
      IO.puts("No live #{@unit_prefix}* scopes.")
    else
      Enum.each(rows, fn {id, active, sub} ->
        IO.puts("#{id}  #{active}/#{sub}")
      end)
    end
  end

  defp parse_units(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 5) do
        [unit, _load, active, sub | _] ->
          case session_id_from_unit(unit) do
            nil -> []
            id -> [{id, active, sub}]
          end

        _ ->
          []
      end
    end)
  end

  defp session_id_from_unit(unit) do
    with @unit_prefix <> rest <- String.trim(unit),
         id when id != "" <- String.trim_trailing(rest, ".scope") do
      id
    else
      _ -> nil
    end
  end

  # ---- attach -----------------------------------------------------------------

  defp attach(args) do
    {read_only?, rest} = extract_flag(args, ["--read-only", "-r"])

    case rest do
      [id | _] ->
        socket = require_socket_path(id)

        unless File.exists?(socket) do
          Output.die(
            "no tmux socket at #{socket} for session #{id}",
            "Run `arb session list` to see live sessions."
          )
        end

        tmux =
          System.find_executable("tmux") ||
            Output.die("tmux not found on PATH", "Install tmux to use the CLI fallback (§4.7).")

        tmux_args =
          ["-S", socket, "attach"] ++
            if(read_only?, do: ["-r"], else: []) ++ ["-t", @tmux_session]

        # `:nouse_stdio` hands the child our actual controlling terminal
        # (rather than a pipe), which full-screen curses-style attach needs
        # for raw mode and SIGWINCH to work at all. `ReleaseEnv.port_env/1`
        # scrubs ROOTDIR/BINDIR/RELEASE_* (bd-2oelme) — a port child inherits
        # them from `arb` when it runs as an installed release, and while tmux
        # itself doesn't care, `Arbiter.Worker.ReleaseEnvGuardTest` requires
        # every `Port.open/2` site to do this regardless of what it spawns.
        port =
          Port.open(
            {:spawn_executable, tmux},
            [:nouse_stdio, :exit_status, args: tmux_args, env: ReleaseEnv.port_env()]
          )

        receive do
          {^port, {:exit_status, status}} -> Output.halt(status)
        end

      [] ->
        Output.die(
          "arb session attach needs a session id",
          "Run `arb session list` to see live sessions."
        )
    end
  end

  defp extract_flag(args, flags) do
    if Enum.any?(flags, &(&1 in args)) do
      {true, Enum.reject(args, &(&1 in flags))}
    else
      {false, args}
    end
  end

  # Server-side (`Arbiter.Sessions.Naming.runtime_dir/0`) has no `/tmp`
  # fallback — `Sessions.launch/1` refuses to launch at all without
  # `XDG_RUNTIME_DIR`, so a socket can never actually exist under `/tmp`.
  # Inventing that path here would send the operator chasing a location the
  # server would never have used; die with the real cause instead.
  defp require_socket_path(id) do
    case System.get_env("XDG_RUNTIME_DIR") do
      nil ->
        Output.die(
          "XDG_RUNTIME_DIR is unset",
          "Coordinator sessions live under a systemd user session's runtime " <>
            "dir. Run from a real login session, or `loginctl enable-linger $USER` " <>
            "and `export XDG_RUNTIME_DIR=/run/user/$(id -u)`."
        )

      runtime_dir ->
        Path.join([runtime_dir, "arbiter", @socket_prefix <> id <> ".sock"])
    end
  end
end
