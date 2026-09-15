defmodule Arbiter.Integration.SessionScopeTest do
  @moduledoc """
  Live-systemd integration test for coordinator sessions (bd-bpt0ag,
  acceptance criteria 2 and 6).

  Everything else about phase 1 is proven against an injectable command
  runner, which is the right way to test the *logic*. It cannot prove the
  thing the design actually rests on: that `systemd-run --user --scope`
  really places the tmux server in a **sibling cgroup** of whatever spawned
  it (RFC §4.1). Getting that wrong is silent — the session looks fine until
  the next `systemctl --user restart arbiter` kills it — so it is measured
  here against the real host.

  ## Not part of the default suite

  Tagged `:live_systemd` and excluded in `test/test_helper.exs`, because it
  spawns real processes on whatever host runs it. Run it deliberately:

      mix test --include live_systemd test/integration/session_scope_test.exs

  It skips itself when `systemd-run` / `systemctl` / `tmux` are missing, when
  there is no systemd **user** manager, or when `XDG_RUNTIME_DIR` is unset.

  ## Teardown discipline

  This repo has a documented incident class around pattern-based kills: a
  `pkill -f tmux` here would take down the operator's own sessions, and
  `pkill -f "mix phx.server"` has taken down the live coordinator more than
  once. So every teardown in this file addresses the **exact** unit name and
  the **exact** socket path that this test created, both derived from a fresh
  UUID, and runs unconditionally via `on_exit`.
  """
  use Arbiter.DataCase, async: false

  @moduletag :live_systemd
  # Real processes, real systemd round-trips.
  @moduletag timeout: 120_000

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Adoption

  # A payload that stays alive and produces output, so "is it really a PTY
  # doing work" has an answer beyond "the unit exists".
  @payload "while true; do date +%s.%N; sleep 0.3; done"

  setup do
    for tool <- ~w(systemd-run systemctl tmux) do
      unless System.find_executable(tool) do
        raise ExUnit.AssertionError, message: "#{tool} not installed"
      end
    end

    runtime_root = System.get_env("XDG_RUNTIME_DIR")

    if is_nil(runtime_root) or not user_manager_running?() do
      # ExUnit has no runtime skip, so make the precondition explicit and
      # loud rather than failing on a confusing assertion later.
      raise ExUnit.AssertionError,
        message:
          "no systemd user manager / XDG_RUNTIME_DIR — run this test on a host " <>
            "with `systemctl --user` available"
    end

    # A scratch socket directory *inside* the real runtime tmpfs: realistic
    # placement, but it cannot collide with a live session's socket dir.
    runtime = Path.join(runtime_root, "arbiter-live-test-#{System.unique_integer([:positive])}")
    previous_runtime = Application.get_env(:arbiter, :sessions_runtime_dir)
    previous_command = Application.get_env(:arbiter, :sessions_launch_command)
    Application.put_env(:arbiter, :sessions_runtime_dir, runtime)
    Application.put_env(:arbiter, :sessions_launch_command, @payload)

    on_exit(fn ->
      restore(:sessions_runtime_dir, previous_runtime)
      restore(:sessions_launch_command, previous_command)
      File.rm_rf(runtime)
    end)

    {:ok, runtime: runtime}
  end

  test "a launched session runs in a sibling cgroup, is adopted, and dies on kill" do
    {:ok, session} = Sessions.launch(cwd: System.tmp_dir!())

    # Whatever this test asserts or raises next, the scope and the tmux server
    # go away — by exact unit name and exact socket path, never by pattern.
    on_exit(fn ->
      _ = cmd("tmux", ["-S", session.tmux_socket, "kill-server"])
      _ = cmd("systemctl", ["--user", "stop", session.scope_unit])
    end)

    assert session.status == :running
    assert session.scope_unit == "arb-session-#{session.id}.scope"

    assert session.tmux_socket ==
             Path.join([
               Application.get_env(:arbiter, :sessions_runtime_dir),
               "arbiter",
               "session-#{session.id}.sock"
             ])

    # ---- AC 2: a real transient scope, running a real tmux server ----------

    assert {"active\n", 0} =
             cmd("systemctl", ["--user", "is-active", session.scope_unit])

    assert {_, 0} = cmd("tmux", ["-S", session.tmux_socket, "has-session", "-t", "coord"])

    # Nobody is attached, and output happens anyway — the §4.5 property the
    # transport phase's replay depends on.
    assert {"", 0} =
             trimmed(
               cmd("tmux", ["-S", session.tmux_socket, "list-clients", "-t", "coord", "-F", "x"])
             )

    assert eventually(fn ->
             {out, 0} =
               cmd("tmux", ["-S", session.tmux_socket, "capture-pane", "-p", "-t", "coord"])

             String.trim(out) != ""
           end),
           "the pane produced no output — the payload never ran"

    # ---- AC 6: the scope is a SIBLING cgroup, not a child of the spawner ---

    {pid, 0} =
      trimmed(
        cmd("tmux", ["-S", session.tmux_socket, "display-message", "-p", "-t", "coord", "\#{pid}"])
      )

    scope_cgroup = File.read!("/proc/#{pid}/cgroup")
    own_cgroup = File.read!("/proc/self/cgroup")

    # Printed, not just asserted: AC 6 asks for cgroup placement to be
    # *evidenced*, and this test is the documented place that reads
    # `/proc/<pid>/cgroup`. It only runs when explicitly included, so this is
    # the measurement's output rather than suite noise.
    IO.puts("""

    [bd-bpt0ag AC 6] cgroup placement, measured:
      spawner (BEAM)  #{String.trim(own_cgroup)}
      tmux (pid #{pid})  #{String.trim(scope_cgroup)}
    """)

    # The tmux server lives in the transient scope systemd created for it…
    assert scope_cgroup =~ session.scope_unit,
           "tmux (pid #{pid}) is not in #{session.scope_unit}:\n#{scope_cgroup}"

    # …and NOT in the cgroup of the process that spawned it. That is the whole
    # mechanism: under `arbiter.service` this is what makes
    # `systemctl --user restart arbiter` — which signals every process in the
    # service's cgroup — unable to reach the session (§4.1).
    refute String.trim(scope_cgroup) == String.trim(own_cgroup),
           "the scope shares the spawner's cgroup, so a restart would kill it:\n#{own_cgroup}"

    refute own_cgroup =~ session.scope_unit

    # ---- AC 4 against real output: the sweep parses real systemctl ----------

    assert {:ok, result} = Adoption.sweep()
    assert session.id in result.adopted
    assert result.ended == []

    # ---- AC 2: kill really kills ------------------------------------------

    assert {:ok, ended} = Sessions.kill(session.id, reason: "integration test")
    assert ended.status == :ended
    assert ended.end_reason == "integration test"

    assert eventually(fn ->
             {out, _} = cmd("systemctl", ["--user", "is-active", session.scope_unit])
             String.trim(out) != "active"
           end),
           "#{session.scope_unit} is still active after kill/2"

    refute match?({_, 0}, cmd("tmux", ["-S", session.tmux_socket, "has-session", "-t", "coord"]))
  end

  test "a session cannot kill its own scope, and stays alive when it tries (§10.1)" do
    {:ok, session} = Sessions.launch(cwd: System.tmp_dir!())

    on_exit(fn ->
      _ = cmd("tmux", ["-S", session.tmux_socket, "kill-server"])
      _ = cmd("systemctl", ["--user", "stop", session.scope_unit])
    end)

    assert {:error, {:self_kill, _}} =
             Sessions.kill(session.id, caller_session_id: session.id)

    # The refusal is not cosmetic: the scope is untouched.
    assert {"active\n", 0} = cmd("systemctl", ["--user", "is-active", session.scope_unit])
    assert {_, 0} = cmd("tmux", ["-S", session.tmux_socket, "has-session", "-t", "coord"])
  end

  # -- helpers ----------------------------------------------------------------

  defp user_manager_running? do
    match?({_, 0}, cmd("systemctl", ["--user", "is-system-running"])) or
      match?({_, 0}, cmd("systemctl", ["--user", "is-active", "basic.target"]))
  end

  # Direct, exact-argument spawns of pure tools. `systemctl` and `tmux` never
  # read ROOTDIR/BINDIR, and no BEAM starts underneath them here — the payload
  # is a `while` loop.
  defp cmd(command, args) when command in ["systemctl", "tmux"] do
    System.cmd(command, args, stderr_to_stdout: true)
  catch
    :error, _ -> {"", 127}
  end

  defp trimmed({out, status}), do: {String.trim(out), status}

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, value), do: Application.put_env(:arbiter, key, value)

  # Poll instead of sleeping blind: real processes take a few milliseconds to
  # start producing and a few more to die.
  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
