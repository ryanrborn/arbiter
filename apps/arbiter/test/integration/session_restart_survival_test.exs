defmodule Arbiter.Integration.SessionRestartSurvivalTest do
  @moduledoc """
  The §4.2 spike as a regression test (bd-b95w36, phase 2 of
  `docs/browser-hosted-coordinator-sessions.md`, §13 row 2).

  **This protects the one property everything else in the RFC assumes:** a
  coordinator session survives `systemctl --user restart arbiter`. If it does
  not, the browser transport, the usage ingest and the whole "the coordinator
  can restart itself" story are built on sand — and the failure is *silent*
  until an operator restarts arbiter and loses their session.

  Phase 1's `Arbiter.Integration.SessionScopeTest` proves the **mechanism**
  (the scope is a sibling cgroup). It cannot prove the **consequence**,
  because it launches from the ExUnit BEAM's own cgroup and nothing restarts
  that. So this test brings up a throwaway systemd user service standing in
  for `arbiter.service` — same user manager, same default `KillMode`, no blast
  radius on the live coordinator — launches a session from inside it through
  the real `Arbiter.Sessions.launch/1`, and restarts it for real.

  What is asserted, mirroring the spike's four observations:

    1. after `systemctl --user restart <stand-in>`, the `arb-session-<id>`
       scope is still `active` and the tmux server is the **same pid** it was
       before;
    2. the pane's sequenced output is contiguous `1..N` across the restart
       instant — the spike's "range 1..58, count 58", with no gap;
    3. **negative control**: a tmux server started as a *plain child* of the
       same unit — the intuitive design, RFC §4.4's "variant A" — is dead
       afterwards. This is what proves the test is capable of failing;
    4. with the stand-in **stopped** rather than restarted, the scope is still
       `active` ("host: inactive   scope: active", §4.6).

  ## Running it

  Excluded from the default suite — it spawns real systemd units. On a host
  with a systemd user instance (the arbiter host has one):

      scripts/session-restart-survival.sh

  which is the documented wrapper around

      mix test --include systemd_user test/integration/session_restart_survival_test.exs

  run from `apps/arbiter` (an umbrella `mix test <path>` at the root is not
  scoped to one app). On a host **without** a user manager the module tags
  itself `skip:` with the reason, and `test/test_helper.exs` prints a banner
  saying, in CI output, that a green suite did not cover restart survival.

  ## Teardown discipline

  Every teardown in this file and in `Arbiter.Test.StandinUnit` addresses the
  **exact** transient unit name, the **exact** scope name and the **exact**
  socket path this test created. This repo has a documented incident class
  around pattern-based kills reaching the live coordinator; there is not a
  single name match anywhere in this path.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.StandinUnit
  alias Arbiter.Test.SystemdUser

  # Opt-in: real units, real restarts.
  @moduletag :systemd_user
  # Real processes, real systemd round-trips, and a restart to wait out.
  @moduletag timeout: 180_000

  # ExUnit has no runtime skip, so the availability answer is baked in at
  # compile time — which is the right granularity anyway: whether this host
  # has a user manager does not change between compiling the suite and
  # running it. The reason travels with the skip so `--include systemd_user`
  # on a CI runner reports *why* rather than failing three lines into `setup`.
  case SystemdUser.status() do
    :ok ->
      :ok

    {:unavailable, reason} ->
      @moduletag skip: "no systemd user instance: #{reason}"
  end

  # Enough ticks on each side of the restart that a lost or duplicated one
  # cannot hide, without making the test slow: at 100 ms a tick this is ~1 s
  # before and ~1 s after.
  @ticks_before 10
  @ticks_after 10

  test "a session launched from inside a stand-in unit survives that unit restarting, with no gap" do
    standin = StandinUnit.start!()

    SessionEnv.override(
      sessions_runtime_dir: Path.join(standin.work, "runtime"),
      sessions_launch_command: StandinUnit.tick_command()
    )

    # `provision: false` is the phase-1 launch shape: no scaffold, no config
    # dir, no credentials — the pane runs the pinned tick payload. What is
    # under test is the cgroup, not the agent.
    {:ok, session} =
      Sessions.launch(cwd: standin.work, provision: false, runner: StandinUnit)

    on_exit(fn ->
      _ = cmd("tmux", ["-S", session.tmux_socket, "kill-server"])
      _ = cmd("systemctl", ["--user", "stop", session.scope_unit])
    end)

    assert session.status == :running

    # ---- the stand-in really is arbiter.service's shape --------------------

    kill_mode = StandinUnit.kill_mode(standin)

    assert kill_mode == "control-group",
           "the stand-in unit has KillMode=#{kill_mode}, so a restart would not " <>
             "signal its whole cgroup and the negative control would be meaningless"

    # Measured against the real thing where it is loaded on this host, so
    # "same KillMode as arbiter.service" is not an assumption.
    case StandinUnit.kill_mode("arbiter.service") do
      "" ->
        IO.puts(
          "[bd-b95w36] arbiter.service is not loaded here; KillMode compared to the default"
        )

      arbiter_kill_mode ->
        assert arbiter_kill_mode == kill_mode,
               "arbiter.service has KillMode=#{arbiter_kill_mode} but the stand-in has " <>
                 "KillMode=#{kill_mode} — the stand-in no longer stands in for it"
    end

    # ---- both PTYs are up, one each way ------------------------------------

    session_pid = tmux_pid(session.tmux_socket)
    plain_pid = StandinUnit.plain_child_pid(standin)

    assert session_pid != nil, "the session's tmux server never started"
    assert plain_pid != nil, "the negative control's tmux server never started"
    assert StandinUnit.alive?(plain_pid)

    session_cgroup = StandinUnit.cgroup(session_pid)
    plain_cgroup = StandinUnit.cgroup(plain_pid)

    # Printed, not just asserted: this is the measurement §4.2 recorded, and
    # the coordinator records this output post-merge (acceptance 6).
    IO.puts("""

    [bd-b95w36] cgroup placement before the restart:
      stand-in unit      #{standin.unit} (MainPID #{StandinUnit.main_pid(standin)})
      tmux, escaped      pid #{session_pid}  #{session_cgroup}
      tmux, plain child  pid #{plain_pid}  #{plain_cgroup}
    """)

    assert session_cgroup =~ session.scope_unit
    assert plain_cgroup =~ standin.unit

    refute session_cgroup =~ standin.unit,
           "the session's tmux server is inside the stand-in unit's cgroup, so the " <>
             "restart below would kill it and this test would be measuring nothing"

    # ---- run up a head of output, then restart -----------------------------

    assert await_ticks(session.tmux_socket, @ticks_before),
           "the session pane never produced #{@ticks_before} ticks"

    before_ticks = ticks(session.tmux_socket)
    before_max = Enum.max(before_ticks)

    {before_main, after_main} = StandinUnit.restart!(standin)

    # ---- (a) the scope is still active -------------------------------------

    assert StandinUnit.active_state(session.scope_unit) == "active",
           "#{session.scope_unit} is #{StandinUnit.active_state(session.scope_unit)} " <>
             "after restarting #{standin.unit}"

    # ---- (b) the tmux server is alive, and is the SAME server --------------

    assert {_out, 0} = cmd("tmux", ["-S", session.tmux_socket, "has-session", "-t", "coord"])

    assert tmux_pid(session.tmux_socket) == session_pid,
           "the session's tmux server was replaced (#{session_pid} -> " <>
             "#{tmux_pid(session.tmux_socket)}) — it did not survive, it restarted"

    assert StandinUnit.alive?(session_pid)

    # ---- (c) output continued with no gap ----------------------------------

    assert await_ticks(session.tmux_socket, before_max + @ticks_after),
           "the pane stopped producing output after the restart (last tick #{before_max})"

    after_ticks = ticks(session.tmux_socket)
    after_max = Enum.max(after_ticks)

    assert after_max > before_max,
           "no tick was produced after the restart, so nothing crossed the restart instant"

    assert after_ticks == Enum.to_list(1..after_max),
           "the pane's tick sequence has a gap across the restart: #{gap_report(after_ticks)}"

    # ---- (d) negative control: the plain child died ------------------------

    refute StandinUnit.alive?(plain_pid),
           "the plain-child tmux server (pid #{plain_pid}) survived the restart — " <>
             "KillMode=control-group did not reach it, so the positive result above " <>
             "proves nothing about escaping the cgroup"

    refute match?(
             {_, 0},
             cmd("tmux", ["-S", standin.plain_socket, "has-session", "-t", "coord"])
           ),
           "the plain-child tmux server is still serving after the restart"

    IO.puts("""

    [bd-b95w36] restart survival, measured:
      #{standin.unit} MainPID  #{before_main} -> #{after_main}
      #{session.scope_unit}  #{StandinUnit.active_state(session.scope_unit)}
      tmux, escaped      pid #{session_pid}  ALIVE
      tmux, plain child  pid #{plain_pid}  DEAD
      pane ticks         range 1..#{after_max}, count #{length(after_ticks)} (restart crossed at #{before_max})
    """)
  end

  test "stopping the stand-in unit leaves the session scope running (§4.6)" do
    standin = StandinUnit.start!()

    SessionEnv.override(
      sessions_runtime_dir: Path.join(standin.work, "runtime"),
      sessions_launch_command: StandinUnit.tick_command()
    )

    {:ok, session} =
      Sessions.launch(cwd: standin.work, provision: false, runner: StandinUnit)

    on_exit(fn ->
      _ = cmd("tmux", ["-S", session.tmux_socket, "kill-server"])
      _ = cmd("systemctl", ["--user", "stop", session.scope_unit])
    end)

    assert await_ticks(session.tmux_socket, 3), "the session pane never produced output"
    session_pid = tmux_pid(session.tmux_socket)

    :ok = StandinUnit.stop!(standin)

    host_state = StandinUnit.active_state(standin.unit)
    scope_state = StandinUnit.active_state(session.scope_unit)

    IO.puts("\n[bd-b95w36] host: #{host_state}   scope: #{scope_state}\n")

    refute host_state == "active", "#{standin.unit} is still active after stop"

    assert scope_state == "active",
           "#{session.scope_unit} is #{scope_state} after the host stopped"

    assert StandinUnit.alive?(session_pid)
    assert {_out, 0} = cmd("tmux", ["-S", session.tmux_socket, "has-session", "-t", "coord"])

    # Still producing: outliving arbiter is not the same as being frozen by it.
    after_stop = Enum.max(ticks(session.tmux_socket))

    assert await_ticks(session.tmux_socket, after_stop + 3),
           "the pane froze once the host stopped"
  end

  # -- helpers ----------------------------------------------------------------

  # The tick sequence currently in the pane's history, in order. The payload
  # prints `tick <n>` every 100 ms, so a contiguous `1..N` is the "no gap"
  # property and any missing number is a lost interval.
  defp ticks(socket) do
    {out, status} =
      cmd("tmux", ["-S", socket, "capture-pane", "-p", "-S", "-", "-t", "coord"])

    if status == 0 do
      ~r/^tick (\d+)$/m
      |> Regex.scan(out)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    else
      []
    end
  end

  defp await_ticks(socket, target, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      case ticks(socket) do
        [] ->
          Process.sleep(50)
          {:cont, false}

        seen ->
          if Enum.max(seen) >= target do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
      end
    end)
  end

  defp gap_report(seen) do
    missing = Enum.to_list(1..Enum.max(seen)) -- seen
    "missing #{inspect(Enum.take(missing, 20))} of 1..#{Enum.max(seen)}"
  end

  defp tmux_pid(socket) do
    {out, status} =
      cmd("tmux", ["-S", socket, "display-message", "-p", "-t", "coord", "\#{pid}"])

    case {String.trim(out), status} do
      {pid, 0} when pid != "" -> pid
      _ -> nil
    end
  end

  # Direct, exact-argument spawns of pure tools. `systemctl` and `tmux` never
  # read ROOTDIR/BINDIR, and no BEAM starts underneath them here — the payload
  # is a `while` loop.
  defp cmd(command, args) when command in ["systemctl", "tmux"] do
    System.cmd(command, args, stderr_to_stdout: true)
  catch
    :error, _ -> {"", 127}
  end
end
