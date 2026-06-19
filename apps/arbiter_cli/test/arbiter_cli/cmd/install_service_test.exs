defmodule ArbiterCli.Cmd.InstallServiceTest do
  # async: false — these tests mutate global env vars (ARB_HOME) and the
  # process dict seams shared with `arb start`.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.InstallService

  setup do
    # Deterministic project root (no filesystem walk) and a tmp dir to write
    # units into so we never touch ~/.config or /etc.
    System.put_env("ARB_HOME", "/tmp/arbiter-install-test")
    # Clear the worker guard so tests aren't blocked when run inside a worker session.
    prior_acolyte_id = System.get_env("ARB_ACOLYTE_BEAD_ID")
    System.delete_env("ARB_ACOLYTE_BEAD_ID")

    unit_dir =
      Path.join(System.tmp_dir!(), "arb-units-#{System.unique_integer([:positive])}")

    Process.put(:bd2_unit_dir, unit_dir)
    # Pin the ExecStart binary so the generated unit is deterministic.
    Process.put(:bd2_arb_exe, "/opt/arbiter/apps/arbiter_cli/arb")
    # Quiet the progress chatter (same seam `arb start` uses).
    Process.put(:bd2_sleep, fn _ -> :ok end)
    # The active-work guard calls GET /api/polecats. Simulate an unreachable
    # server so the guard always proceeds (no active polecats can exist when
    # the server is down). Tests that want active polecats override this.
    stub_transport_error(:get, "/api/polecats", :econnrefused)

    on_exit(fn ->
      System.delete_env("ARB_HOME")
      File.rm_rf(unit_dir)
      if prior_acolyte_id, do: System.put_env("ARB_ACOLYTE_BEAD_ID", prior_acolyte_id)
    end)

    {:ok, unit_dir: unit_dir}
  end

  # Record every shelled-out command and report success.
  defp record_cmds do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {"", 0}
    end)
  end

  describe "install (user scope)" do
    test "writes the unit, reloads, enables, and enables linger", %{unit_dir: dir} do
      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0

      unit = Path.join(dir, "arbiter.service")
      assert File.exists?(unit)

      contents = File.read!(unit)
      assert contents =~ "ExecStart=/opt/arbiter/apps/arbiter_cli/arb start --timeout"
      assert contents =~ "Type=oneshot"
      assert contents =~ "RemainAfterExit=yes"
      assert contents =~ "WantedBy=default.target"
      assert contents =~ "WorkingDirectory=/tmp/arbiter-install-test"
      # MIX_HOME must be pinned so Phoenix/Mix can boot under systemd.
      assert contents =~ "Environment=MIX_HOME="

      # Orchestration, in the user manager, in order.
      assert_received {:cmd, "systemctl", ["--user", "daemon-reload"]}
      assert_received {:cmd, "systemctl", ["--user", "enable", "--now", "arbiter.service"]}
      assert_received {:cmd, "loginctl", ["enable-linger" | _]}

      # Guidance: unit path + how to check status/logs + linger.
      assert out =~ unit
      assert out =~ "systemctl --user status arbiter.service"
      assert out =~ "journalctl --user -u arbiter.service"
      assert out =~ "linger"
    end

    test "--json reports the install action and paths", %{unit_dir: dir} do
      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["action"] == "install"
      assert payload["scope"] == "user"
      assert payload["ok"] == true
      assert payload["unit_path"] == Path.join(dir, "arbiter.service")
    end

    test "is idempotent — running twice succeeds and rewrites the unit" do
      record_cmds()

      {_o1, _e1, c1} = capture(fn -> InstallService.run([]) end)
      {_o2, _e2, c2} = capture(fn -> InstallService.run([]) end)

      assert c1 == 0
      assert c2 == 0
    end
  end

  describe "install (system scope)" do
    test "uses the system manager and docker ordering", %{unit_dir: dir} do
      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run(["--system"]) end)

      assert code == 0

      contents = File.read!(Path.join(dir, "arbiter.service"))
      assert contents =~ "WantedBy=multi-user.target"
      assert contents =~ "After=network-online.target docker.service"

      # No `--user`, and no linger for a system unit.
      assert_received {:cmd, "systemctl", ["daemon-reload"]}
      assert_received {:cmd, "systemctl", ["enable", "--now", "arbiter.service"]}
      refute_received {:cmd, "loginctl", _}

      assert out =~ "systemctl status arbiter.service"
    end
  end

  describe "uninstall" do
    test "disables, removes the unit, and reloads", %{unit_dir: dir} do
      # Pre-seed an installed unit.
      File.mkdir_p!(dir)
      unit = Path.join(dir, "arbiter.service")
      File.write!(unit, "[Service]\n")

      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run(["--uninstall"]) end)

      assert code == 0
      refute File.exists?(unit)

      assert_received {:cmd, "systemctl", ["--user", "disable", "--now", "arbiter.service"]}
      assert_received {:cmd, "systemctl", ["--user", "daemon-reload"]}

      assert out =~ "Uninstalled"
    end

    test "is idempotent when nothing is installed", %{unit_dir: dir} do
      # disable --now returns non-zero for a unit that isn't there; tolerate it.
      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        if args == ["--user", "disable", "--now", "arbiter.service"],
          do: {"not loaded", 1},
          else: {"", 0}
      end)

      {out, _err, code} = capture(fn -> InstallService.run(["--uninstall"]) end)

      assert code == 0
      refute File.exists?(Path.join(dir, "arbiter.service"))
      assert out =~ "was not enabled"
    end
  end

  describe "failure modes" do
    test "aborts with exit 1 when systemctl is missing" do
      Process.put(:bd2_cmd_runner, fn "systemctl", _args, _opts ->
        raise ErlangError, original: :enoent
      end)

      {_out, err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 1
      assert err =~ "could not run systemctl"
    end

    test "warns but succeeds when loginctl is unavailable", %{unit_dir: dir} do
      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case cmd do
          "loginctl" -> raise ErlangError, original: :enoent
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      assert File.exists?(Path.join(dir, "arbiter.service"))
      assert out =~ "could not enable linger"
    end
  end

  describe "unit_contents/2" do
    test "user units omit docker ordering (can't cross the manager boundary)" do
      contents = InstallService.unit_contents(:user, "/srv/arbiter")
      refute contents =~ "docker.service"
      assert contents =~ "WantedBy=default.target"
      assert contents =~ "EnvironmentFile=-/srv/arbiter/.arbiter.env"
    end

    test "pins MIX_HOME so Mix can resolve archives/escripts under systemd" do
      mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
      contents = InstallService.unit_contents(:user, "/srv/arbiter")
      assert contents =~ "Environment=MIX_HOME=#{mix_home}"
    end

    test "includes Restart=on-failure and RestartSec so systemd auto-retries" do
      contents = InstallService.unit_contents(:user, "/srv/arbiter")
      assert contents =~ "Restart=on-failure"
      assert contents =~ "RestartSec=10"
    end
  end
end
