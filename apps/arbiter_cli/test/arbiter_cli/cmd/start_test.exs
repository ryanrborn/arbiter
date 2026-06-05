defmodule ArbiterCli.Cmd.StartTest do
  # async: false — these tests mutate the global ARB_HOME env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Start

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  setup do
    # Make project-root resolution deterministic: with ARB_HOME set we never
    # walk the filesystem looking for compose.yml. The commands themselves are
    # stubbed (see :bd2_cmd_runner), so the path need not actually exist.
    System.put_env("ARB_HOME", "/tmp/arbiter-start-test")
    on_exit(fn -> System.delete_env("ARB_HOME") end)
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
    test "brings Postgres + Phoenix up, waits for green, exits 0" do
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

      # Both stack components were started, in order.
      assert_received {:cmd, "docker", ["compose", "up", "-d"]}
      assert_received {:cmd, "sh", ["-c", script]}
      assert script =~ "mix phx.server"
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

    test "--json lists the postgres and phoenix actions" do
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
      assert "postgres" in components
      assert "phoenix" in components
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

    test "aborts with exit 1 when docker is missing" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      Process.put(:bd2_sleep, fn _ms -> :ok end)

      # Mirror System.cmd/3 raising :enoent when the executable isn't found.
      Process.put(:bd2_cmd_runner, fn "docker", _args, _opts ->
        raise ErlangError, original: :enoent
      end)

      {_out, err, code} = capture(fn -> Start.run([]) end)

      assert code == 1
      assert err =~ "could not run docker"
    end
  end

  describe "project_root/0" do
    test "honors ARB_HOME" do
      System.put_env("ARB_HOME", "/tmp/some/arbiter/home")
      assert {:ok, "/tmp/some/arbiter/home"} = Start.project_root()
    end
  end
end
