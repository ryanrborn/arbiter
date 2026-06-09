defmodule ArbiterCli.Cmd.StartTest do
  # async: false — these tests mutate the global ARB_HOME env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Start

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  setup do
    # Make project-root resolution deterministic: with ARB_HOME set we never
    # walk the filesystem looking for mix.exs. The commands themselves are
    # stubbed (see :bd2_cmd_runner), so the path need not actually exist.
    System.put_env("ARB_HOME", "/tmp/arbiter-start-test")
    # Clear the acolyte guard so tests aren't blocked when run inside an acolyte session.
    prior_acolyte_id = System.get_env("ARB_ACOLYTE_BEAD_ID")
    System.delete_env("ARB_ACOLYTE_BEAD_ID")

    on_exit(fn ->
      System.delete_env("ARB_HOME")
      if prior_acolyte_id, do: System.put_env("ARB_ACOLYTE_BEAD_ID", prior_acolyte_id)
    end)

    :ok
  end

  describe "already running (no-op)" do
    test "detects a reachable stack and touches nothing" do
      stub_get("/api/workspaces", @green)

      # Any attempt to shell out on the no-op path is a bug.
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        raise "no commands should run when the stack is already up"
      end)

      {out, _err, code} = capture(fn -> Start.run([]) end)

      assert code == 0
      assert out =~ "already running"
      assert out =~ "[ ok ] phoenix reachable"
    end

    test "--json reports already_running with no actions" do
      stub_get("/api/workspaces", @green)

      {out, _err, code} = capture(fn -> Start.run(["--json"]) end)

      assert code == 0

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["already_running"] == true
      assert payload["ok"] == true
      assert payload["actions"] == []
    end
  end

  describe "cold start" do
    test "brings Phoenix up, waits for green, exits 0" do
      # Start unreachable; flip to green once Phoenix is "started".
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})
        # Starting Phoenix is what makes the API reachable.
        if cmd == "sh", do: stub_get("/api/workspaces", @green)
        {"", 0}
      end)

      {out, _err, code} = capture(fn -> Start.run([]) end)

      assert code == 0
      assert out =~ "Arbiter stack is up"
      assert out =~ "[ ok ] phoenix reachable"

      assert_received {:cmd, "sh", ["-c", script]}
      assert script =~ "mix phx.server"
      refute_received {:cmd, "docker", _}
    end

    test "script sources .arbiter.env with set -a so all vars are exported" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})
        if cmd == "sh", do: stub_get("/api/workspaces", @green)
        {"", 0}
      end)

      {_out, _err, code} = capture(fn -> Start.run([]) end)

      assert code == 0
      assert_received {:cmd, "sh", ["-c", script]}
      # Shell-level conditional so it's always present in the script string.
      assert script =~ ".arbiter.env"
      assert script =~ "set -a"
      assert script =~ "mix phx.server"
    end

    test "--json lists the phoenix action" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        if cmd == "sh", do: stub_get("/api/workspaces", @green)
        {"", 0}
      end)

      {out, _err, code} = capture(fn -> Start.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["already_running"] == false
      assert payload["ok"] == true

      components = Enum.map(payload["actions"], & &1["component"])
      assert "phoenix" in components
      refute "postgres" in components
    end

    test "spawns Phoenix with cd set to the project root when .run-server.sh is absent" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args, opts})
        if cmd == "sh", do: stub_get("/api/workspaces", @green)
        {"", 0}
      end)

      capture(fn -> Start.run([]) end)

      assert_received {:cmd, "sh", ["-c", _script], opts}
      assert Keyword.get(opts, :cd) == "/tmp/arbiter-start-test"
    end

    test "delegates to .run-server.sh when it exists in the project root" do
      arb_home = System.get_env("ARB_HOME")
      File.mkdir_p!(arb_home)
      run_sh = Path.join(arb_home, ".run-server.sh")
      File.write!(run_sh, "#!/bin/sh\nexec mix phx.server\n")
      on_exit(fn -> File.rm(run_sh) end)

      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args, opts})
        if cmd == "sh", do: stub_get("/api/workspaces", @green)
        {"", 0}
      end)

      capture(fn -> Start.run([]) end)

      assert_received {:cmd, "sh", ["-c", script], opts}
      assert script =~ ".run-server.sh"
      refute Keyword.has_key?(opts, :cd)
    end

    test "times out with exit 1 when the stack never comes up" do
      # Never flips — the API stays refused for the whole wait loop.
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts -> {"", 0} end)

      {out, _err, code} = capture(fn -> Start.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come up within 1s"
      assert out =~ "[fail] phoenix reachable"
    end
  end

  describe "project_root/0" do
    test "honors ARB_HOME" do
      System.put_env("ARB_HOME", "/tmp/some/arbiter/home")
      assert {:ok, "/tmp/some/arbiter/home"} = Start.project_root()
    end
  end
end
