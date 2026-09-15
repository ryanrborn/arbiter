defmodule Arbiter.Sessions.WatchdogScriptTest do
  @moduledoc """
  The in-scope dead-man's switch (bd-3qkbch, RFC §4.6.3, phase 10) — the
  actual `watchdog.sh` `Arbiter.Sessions.Provisioning` generates, run as a
  real `/bin/sh` subprocess against a **fake** `tmux` on `PATH`.

  This is deliberately not a unit test of Elixir code: the switch's whole
  point is to keep working with arbiter (and therefore the BEAM) gone
  entirely, so the thing under test has to be the shell script itself, not a
  model of it. "Injectable liveness" (the acceptance criterion) is the fake
  `tmux` plus a heartbeat file whose mtime the test sets directly — both
  liveness signals the real script reads are swappable without touching a
  real tmux server or a real arbiter process.

  Every test bounds real wall-clock time with the `timeout` utility: the
  script is a `while :; do sleep POLL; ...; done` loop, and the tests that
  assert "does NOT kill" would otherwise hang forever on a poll that never
  triggers a kill and never allows into the tests structurally.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Test.SessionRunnerStub

  # Grace comfortably longer than the bound the "does NOT kill" tests give
  # `timeout`, and the poll short enough that the "DOES kill" test still
  # finishes quickly.
  @grace_seconds 5
  @poll_seconds 1

  setup do
    base = Path.join(System.tmp_dir!(), "bd-3qkbch-wd-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(base, "bin")
    fake_tmux_dir = Path.join(base, "fake-tmux")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(fake_tmux_dir)
    write_fake_tmux!(Path.join(fake_bin, "tmux"))

    env = Arbiter.Test.SessionEnv.sandbox("watchdog")
    SessionRunnerStub.reset()
    SessionRunnerStub.script(fn _cmd, _args, _opts -> {"", 0} end)

    on_exit(fn -> File.rm_rf(base) end)

    {:ok,
     base: base,
     fake_bin: fake_bin,
     fake_tmux_dir: fake_tmux_dir,
     sessions_root: env[:sessions_root]}
  end

  # A fake tmux that logs every invocation and answers from files a test
  # writes into $FAKE_TMUX_DIR — the "injectable liveness" for the tmux side.
  defp write_fake_tmux!(path) do
    File.write!(path, """
    #!/bin/sh
    echo "$*" >> "$FAKE_TMUX_DIR/calls.log"
    case "$*" in
      *has-session*)
        if [ -f "$FAKE_TMUX_DIR/no-session" ]; then exit 1; else exit 0; fi
        ;;
      *list-clients*)
        [ -f "$FAKE_TMUX_DIR/clients" ] && cat "$FAKE_TMUX_DIR/clients"
        exit 0
        ;;
      *kill-session*)
        touch "$FAKE_TMUX_DIR/killed"
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end

  defp launch_watchdog!(_fake_bin) do
    {:ok, session} =
      Sessions.launch(
        cwd: "/tmp",
        runner: SessionRunnerStub,
        deadman_grace_seconds: @grace_seconds,
        deadman_poll_seconds: @poll_seconds
      )

    Layout.watchdog_script_path(session.id)
  end

  defp run_bounded(script, fake_bin, fake_tmux_dir, seconds) do
    System.cmd(
      "timeout",
      [to_string(seconds), script],
      env: [
        {"PATH", fake_bin <> ":" <> System.get_env("PATH")},
        {"FAKE_TMUX_DIR", fake_tmux_dir}
      ],
      stderr_to_stdout: true
    )
  end

  defp stale_heartbeat! do
    {:ok, heartbeat} = Arbiter.Sessions.Naming.heartbeat_path()
    File.mkdir_p!(Path.dirname(heartbeat))
    File.write!(heartbeat, "stale")
    # Well past any grace window this test suite uses. `File.touch!/2`
    # accepts a POSIX time directly.
    File.touch!(heartbeat, System.os_time(:second) - 10_000)
  end

  defp fresh_heartbeat! do
    {:ok, heartbeat} = Arbiter.Sessions.Naming.heartbeat_path()
    File.mkdir_p!(Path.dirname(heartbeat))
    File.write!(heartbeat, DateTime.to_iso8601(DateTime.utc_now()))
  end

  test "kills the session and exits once the heartbeat is stale and no client is attached",
       %{fake_bin: fake_bin, fake_tmux_dir: fake_tmux_dir} do
    stale_heartbeat!()
    script = launch_watchdog!(fake_bin)

    {_out, status} = run_bounded(script, fake_bin, fake_tmux_dir, 8)

    assert status == 0
    assert File.regular?(Path.join(fake_tmux_dir, "killed"))
  end

  test "does not kill while a client is attached, even with a stale heartbeat",
       %{fake_bin: fake_bin, fake_tmux_dir: fake_tmux_dir} do
    stale_heartbeat!()
    File.write!(Path.join(fake_tmux_dir, "clients"), "client-1\n")
    script = launch_watchdog!(fake_bin)

    {_out, status} = run_bounded(script, fake_bin, fake_tmux_dir, 3)

    # `timeout` kills a process that outlives the bound with 124 — the
    # expected outcome, since the script must keep polling forever here.
    assert status == 124
    refute File.regular?(Path.join(fake_tmux_dir, "killed"))
  end

  test "does not kill while the heartbeat is fresh, even with no client attached",
       %{fake_bin: fake_bin, fake_tmux_dir: fake_tmux_dir} do
    fresh_heartbeat!()
    script = launch_watchdog!(fake_bin)

    {_out, status} = run_bounded(script, fake_bin, fake_tmux_dir, 3)

    assert status == 124
    refute File.regular?(Path.join(fake_tmux_dir, "killed"))
  end

  test "exits cleanly (no kill) once the tmux session is already gone",
       %{fake_bin: fake_bin, fake_tmux_dir: fake_tmux_dir} do
    stale_heartbeat!()
    File.write!(Path.join(fake_tmux_dir, "no-session"), "")
    script = launch_watchdog!(fake_bin)

    {_out, status} = run_bounded(script, fake_bin, fake_tmux_dir, 5)

    assert status == 0
    refute File.regular?(Path.join(fake_tmux_dir, "killed"))
  end
end
