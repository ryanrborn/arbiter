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
    prior_worker_id = System.get_env("ARB_ACOLYTE_BEAD_ID")
    System.delete_env("ARB_ACOLYTE_BEAD_ID")

    unit_dir =
      Path.join(System.tmp_dir!(), "arb-units-#{System.unique_integer([:positive])}")

    # Redirect arbiter_home to a temp dir so capture_path / capture_secrets
    # never write to the real ~/.arbiter/arbiter.env. Without this seam, tests
    # that set PATH to a test value (e.g. "/second/path:/usr/bin") would
    # corrupt the production env file, breaking worker spawns after the next
    # `arb server deploy` triggers a systemd restart.
    arbiter_home =
      Path.join(System.tmp_dir!(), "arb-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(arbiter_home)

    Process.put(:bd2_unit_dir, unit_dir)
    Process.put(:bd2_arbiter_home, arbiter_home)
    # Quiet the progress chatter (same seam `arb start` uses).
    Process.put(:bd2_sleep, fn _ -> :ok end)
    # The active-work guard calls GET /api/workers. Simulate an unreachable
    # server so the guard always proceeds (no active workers can exist when
    # the server is down). Tests that want active workers override this.
    stub_transport_error(:get, "/api/workers", :econnrefused)

    on_exit(fn ->
      System.delete_env("ARB_HOME")
      File.rm_rf(unit_dir)
      File.rm_rf(arbiter_home)
      if prior_worker_id, do: System.put_env("ARB_ACOLYTE_BEAD_ID", prior_worker_id)
    end)

    {:ok, unit_dir: unit_dir, arbiter_home: arbiter_home}
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
    test "writes the unit, reloads, enables, and enables linger", %{
      unit_dir: dir,
      arbiter_home: arbiter_home
    } do
      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0

      unit = Path.join(dir, "arbiter.service")
      assert File.exists?(unit)

      contents = File.read!(unit)
      assert contents =~ "ExecStart=#{arbiter_home}/current/bin/arbiter start"
      assert contents =~ "Type=exec"
      refute contents =~ "RemainAfterExit"
      assert contents =~ "WantedBy=default.target"
      assert contents =~ "WorkingDirectory=#{arbiter_home}"
      assert contents =~ "EnvironmentFile=-#{arbiter_home}/arbiter.env"
      # Release is self-contained — no MIX_HOME needed in the unit.
      refute contents =~ "Environment=MIX_HOME="

      # Orchestration, in the user manager, in order.
      assert_received {:cmd, "systemctl", ["--user", "daemon-reload"]}
      assert_received {:cmd, "systemctl", ["--user", "enable", "--now", "arbiter.service"]}
      assert_received {:cmd, "loginctl", ["enable-linger" | _]}

      # Guidance: unit path + how to check status/logs + linger.
      assert out =~ unit
      assert out =~ "systemctl --user status arbiter.service"
      assert out =~ "tail -f #{Path.join([arbiter_home, "log", "arbiter.log"])}"
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

    test "unit routes stdout/stderr to a file so logs survive reboots and need no journald group",
         %{unit_dir: dir, arbiter_home: arbiter_home} do
      record_cmds()

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      contents = File.read!(Path.join(dir, "arbiter.service"))
      expected_log = Path.join([arbiter_home, "log", "arbiter.log"])
      assert contents =~ "StandardOutput=append:#{expected_log}"
      assert contents =~ "StandardError=append:#{expected_log}"
    end

    test "creates the log directory and writes a logrotate config", %{arbiter_home: arbiter_home} do
      record_cmds()

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      log_dir = Path.join(arbiter_home, "log")
      assert File.dir?(log_dir)

      logrotate_conf = Path.join(log_dir, "logrotate.conf")
      assert File.exists?(logrotate_conf)
      conf_contents = File.read!(logrotate_conf)
      assert conf_contents =~ "arbiter.log"
      assert conf_contents =~ "copytruncate"
      assert conf_contents =~ "rotate 7"
    end

    test "output includes the log file path and rotation command", %{arbiter_home: arbiter_home} do
      record_cmds()

      {out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      assert out =~ Path.join([arbiter_home, "log", "arbiter.log"])
      assert out =~ "logrotate"
    end

    test "is idempotent — running twice succeeds and rewrites the unit" do
      record_cmds()

      {_o1, _e1, c1} = capture(fn -> InstallService.run([]) end)
      {_o2, _e2, c2} = capture(fn -> InstallService.run([]) end)

      assert c1 == 0
      assert c2 == 0
    end

    test "writes PATH from the installing shell into arbiter.env so the service finds agent CLIs",
         %{arbiter_home: arbiter_home} do
      record_cmds()

      System.put_env("PATH", "/custom/bin:/usr/bin")

      on_exit(fn ->
        System.delete_env("PATH")
      end)

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0

      env_file = Path.join(arbiter_home, "arbiter.env")
      assert File.exists?(env_file)
      env_contents = File.read!(env_file)
      assert env_contents =~ "PATH=/custom/bin:/usr/bin"
    end

    test "PATH in arbiter.env is updated on re-install (idempotent)", %{
      arbiter_home: arbiter_home
    } do
      record_cmds()

      System.put_env("PATH", "/first/path:/usr/bin")

      {_o1, _e1, c1} = capture(fn -> InstallService.run([]) end)

      System.put_env("PATH", "/second/path:/usr/bin")

      {_o2, _e2, c2} = capture(fn -> InstallService.run([]) end)

      on_exit(fn ->
        System.delete_env("PATH")
      end)

      assert c1 == 0
      assert c2 == 0

      env_file = Path.join(arbiter_home, "arbiter.env")
      env_contents = File.read!(env_file)
      # The latest PATH wins; the old one is gone.
      assert env_contents =~ "PATH=/second/path:/usr/bin"
      refute env_contents =~ "/first/path"
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
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter")
      refute contents =~ "docker.service"
      assert contents =~ "WantedBy=default.target"
      assert contents =~ "EnvironmentFile=-/home/user/.arbiter/arbiter.env"
    end

    test "uses the release binary as ExecStart" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter")
      assert contents =~ "ExecStart=/home/user/.arbiter/current/bin/arbiter start"
      assert contents =~ "Type=exec"
      refute contents =~ "RemainAfterExit"
    end

    test "does not bake MIX_HOME or PATH directly into the unit (PATH goes in EnvironmentFile instead)" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter")
      refute contents =~ "MIX_HOME"
      refute contents =~ ~r/Environment=PATH=/
    end

    test "includes Restart=on-failure and RestartSec so systemd auto-retries" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter")
      assert contents =~ "Restart=on-failure"
      assert contents =~ "RestartSec=10"
    end

    test "user unit routes output to a file so logs survive reboots without journald group" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter")
      assert contents =~ "StandardOutput=append:/home/user/.arbiter/log/arbiter.log"
      assert contents =~ "StandardError=append:/home/user/.arbiter/log/arbiter.log"
    end

    test "system unit omits file-based log directives (journald is fine with root)" do
      contents = InstallService.unit_contents(:system, "/home/user/.arbiter")
      refute contents =~ "StandardOutput="
      refute contents =~ "StandardError="
    end
  end
end
