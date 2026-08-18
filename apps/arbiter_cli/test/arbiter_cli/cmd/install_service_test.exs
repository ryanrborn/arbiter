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
    prior_worker_id = System.get_env("ARB_WORKER_BEAD_ID")
    System.delete_env("ARB_WORKER_BEAD_ID")

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
      if prior_worker_id, do: System.put_env("ARB_WORKER_BEAD_ID", prior_worker_id)
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

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/custom/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
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

      prior_path = System.get_env("PATH")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      System.put_env("PATH", "/first/path:/usr/bin")

      {_o1, _e1, c1} = capture(fn -> InstallService.run([]) end)

      System.put_env("PATH", "/second/path:/usr/bin")

      {_o2, _e2, c2} = capture(fn -> InstallService.run([]) end)

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

  describe "unit_contents/3 (release mode — root is not a source checkout)" do
    test "user units omit docker ordering (can't cross the manager boundary)" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      refute contents =~ "docker.service"
      assert contents =~ "WantedBy=default.target"
      assert contents =~ "EnvironmentFile=-/home/user/.arbiter/arbiter.env"
    end

    test "uses the release binary as ExecStart" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      assert contents =~ "ExecStart=/home/user/.arbiter/current/bin/arbiter start"
      assert contents =~ "Type=exec"
      refute contents =~ "RemainAfterExit"
    end

    test "does not bake MIX_HOME or PATH directly into the unit (PATH goes in EnvironmentFile instead)" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      refute contents =~ "MIX_HOME"
      refute contents =~ ~r/Environment=PATH=/
    end

    test "includes Restart=on-failure and RestartSec so systemd auto-retries" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      assert contents =~ "Restart=on-failure"
      assert contents =~ "RestartSec=10"
    end

    test "user unit routes output to a file so logs survive reboots without journald group" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      assert contents =~ "StandardOutput=append:/home/user/.arbiter/log/arbiter.log"
      assert contents =~ "StandardError=append:/home/user/.arbiter/log/arbiter.log"
    end

    test "system unit omits file-based log directives (journald is fine with root)" do
      contents =
        InstallService.unit_contents(:system, "/home/user/.arbiter", "/home/user/.arbiter")

      refute contents =~ "StandardOutput="
      refute contents =~ "StandardError="
    end

    test "a root with no mix.exs/apps is release mode even if it happens to share a path prefix" do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", "/home/user/.arbiter")
      refute contents =~ ".run-server.sh"
    end

    test "a root with only compose.yml (no mix.exs/apps) is release mode, not dev mode" do
      root = Path.join(System.tmp_dir!(), "arb-composeonly-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "compose.yml"), "# postgres only\n")
      on_exit(fn -> File.rm_rf!(root) end)

      contents = InstallService.unit_contents(:user, root, root)

      refute contents =~ ".run-server.sh"
      assert contents =~ "ExecStart=#{root}/current/bin/arbiter start"
    end
  end

  describe "unit_contents/3 (dev mode — root is a source checkout)" do
    setup do
      root = Path.join(System.tmp_dir!(), "arb-devroot-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "apps"))
      File.write!(Path.join(root, "mix.exs"), "# fake umbrella mix.exs\n")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "points ExecStart at the dev-mode launcher instead of the release binary", %{root: root} do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "ExecStart=/bin/sh #{root}/.run-server.sh"
      refute contents =~ "current/bin/arbiter start"
      assert contents =~ "Type=exec"
    end

    test "keeps WorkingDirectory at the checkout root, not the arbiter data home", %{root: root} do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "WorkingDirectory=#{root}"
    end

    test "still uses the arbiter_home EnvironmentFile for captured secrets/PATH", %{root: root} do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "EnvironmentFile=-/home/user/.arbiter/arbiter.env"
    end

    test "forwards ARB_HOME=root so subprocesses resolve the same checkout", %{root: root} do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "Environment=ARB_HOME=#{root}"
    end

    test "raises TimeoutStartSec so a cold mix compile doesn't get killed as a startup failure",
         %{
           root: root
         } do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "TimeoutStartSec=900"
    end

    test "keeps Restart=on-failure and file-based logging, same as release mode", %{root: root} do
      contents = InstallService.unit_contents(:user, "/home/user/.arbiter", root)
      assert contents =~ "Restart=on-failure"
      assert contents =~ "RestartSec=10"
      assert contents =~ "StandardOutput=append:/home/user/.arbiter/log/arbiter.log"
    end

    test "system scope keeps docker ordering and drops file-based logging, same as release mode",
         %{
           root: root
         } do
      contents = InstallService.unit_contents(:system, "/home/user/.arbiter", root)
      assert contents =~ "After=network-online.target docker.service"
      assert contents =~ "WantedBy=multi-user.target"
      refute contents =~ "StandardOutput="
    end
  end

  describe "install writes .run-server.sh for a dev-mode checkout" do
    setup %{unit_dir: _dir} do
      root = Path.join(System.tmp_dir!(), "arb-devroot-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "apps"))
      File.write!(Path.join(root, "mix.exs"), "# fake umbrella mix.exs\n")
      System.put_env("ARB_HOME", root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "generates .run-server.sh when absent and points the unit at it", %{
      root: root,
      unit_dir: dir
    } do
      record_cmds()

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0

      script = Path.join(root, ".run-server.sh")
      assert File.exists?(script)
      assert File.read!(script) =~ "exec mix phx.server"

      unit_contents = File.read!(Path.join(dir, "arbiter.service"))
      assert unit_contents =~ "ExecStart=/bin/sh #{script}"
    end

    test "generated .run-server.sh sources the checkout's .arbiter.env before exec", %{
      root: root
    } do
      record_cmds()

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0

      script_body = File.read!(Path.join(root, ".run-server.sh"))
      assert script_body =~ ~s(. ./.arbiter.env)

      # Must source .arbiter.env *before* exec-ing mix, not after.
      source_index = :binary.match(script_body, ".arbiter.env") |> elem(0)
      exec_index = :binary.match(script_body, "exec mix phx.server") |> elem(0)
      assert source_index < exec_index
    end

    test "never overwrites an existing .run-server.sh", %{root: root} do
      record_cmds()

      script = Path.join(root, ".run-server.sh")
      File.write!(script, "#!/bin/sh\necho custom launcher\n")

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      assert File.read!(script) =~ "custom launcher"
    end

    test "re-running keeps generating a dev-mode unit (no flip-flop to release mode)", %{
      unit_dir: dir
    } do
      record_cmds()

      {_o1, _e1, c1} = capture(fn -> InstallService.run([]) end)
      {_o2, _e2, c2} = capture(fn -> InstallService.run([]) end)

      assert c1 == 0
      assert c2 == 0

      contents = File.read!(Path.join(dir, "arbiter.service"))
      assert contents =~ ".run-server.sh"
      refute contents =~ "current/bin/arbiter start"
    end
  end
end
