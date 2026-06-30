defmodule ArbiterCli.Cmd.ServerTest do
  # async: false — tests that mutate ARB_HOME / ARB_ACOLYTE_BEAD_ID and route
  # through the shared `:bd2_cmd_runner` / `:bd2_sleep` process-dict seams.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Server

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}
  @no_workers %{"data" => []}

  setup do
    System.delete_env("ARB_ACOLYTE_BEAD_ID")
    System.delete_env("ARB_HOME")
    :ok
  end

  # ---- migrate: server is DOWN (standalone migration path) ----------------

  describe "migrate — server down" do
    setup do
      # Simulate server unreachable so Doctor.reachable?() returns false and we
      # take the standalone migration path.
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      System.put_env("ARB_HOME", System.tmp_dir!())
      :ok
    end

    test "runs standalone migrations and reports the applied count" do
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        {~s({"migrations_applied":3,"status":"ok"}), 0}
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate"]) end)
      assert code == 0
      assert out =~ "Applied 3 migration(s)"
    end

    test "reports a current schema when nothing to apply" do
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        {~s({"migrations_applied":0,"status":"ok"}), 0}
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate"]) end)
      assert code == 0
      assert out =~ "already current"
    end

    test "--json emits machine-readable output with migrations_applied count" do
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        {~s({"migrations_applied":2,"status":"ok"}), 0}
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate", "--json"]) end)
      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["migrations_applied"] == 2
      assert payload["status"] == "ok"
    end
  end

  # ---- migrate: server is RUNNING (restart path) --------------------------

  describe "migrate — server running" do
    setup do
      System.put_env("ARB_HOME", System.tmp_dir!())
      System.delete_env("ARB_ACOLYTE_BEAD_ID")
      Process.put(:bd2_sleep, fn _ms -> :ok end)
      # Port check seam: report port as free so wait_port_free returns immediately.
      Process.put(:bd2_port_check, fn _port -> true end)

      # /api/workspaces green (server reachable) + /api/workers empty (no active workers).
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ])

      :ok
    end

    test "restarts the server (applies migrations via Boot.Migrator on boot)" do
      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case {cmd, args} do
          # No systemd unit installed — fall back to the SIGTERM+sh path.
          {"systemctl", ["--user", "cat", "arbiter.service"]} ->
            {"", 1}

          # Nothing listening on the port (already down).
          {"lsof", _} ->
            {"", 1}

          # Starting Phoenix — flip the API to green.
          {"sh", _} ->
            stub_get("/api/workspaces", @green)
            {"", 0}

          _ ->
            {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate"]) end)

      assert code == 0
      assert out =~ "restarted" or out =~ "Arbiter"
      # The restart lifecycle was triggered, not a standalone mix migrate.
      refute_received {:cmd, "mix", ["arbiter.migrate"]}
      assert_received {:cmd, "sh", ["-c", script]}
      assert script =~ "mix phx.server"
    end

    test "--json emits restarted: true" do
      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        case {cmd, args} do
          {"systemctl", ["--user", "cat", "arbiter.service"]} ->
            {"", 1}

          {"lsof", _} ->
            {"", 1}

          {"sh", _} ->
            stub_get("/api/workspaces", @green)
            {"", 0}

          _ ->
            {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate", "--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["restarted"] == true
      assert payload["status"] == "ok"
    end

    test "active-worker guard blocks migrate without --force" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"},
         {%{"data" => [%{"task_id" => "bd-abc", "status" => "running"}]}, 200}}
      ])

      {_out, err, code} = capture(fn -> Server.run(["migrate"]) end)

      assert code == 1
      assert err =~ "worker"
      assert err =~ "--force"
    end

    test "--force migrates even with active workers" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"},
         {%{"data" => [%{"task_id" => "bd-abc", "status" => "running"}]}, 200}}
      ])

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        case {cmd, args} do
          {"systemctl", ["--user", "cat", "arbiter.service"]} ->
            {"", 1}

          {"lsof", _} ->
            {"", 1}

          {"sh", _} ->
            stub_get("/api/workspaces", @green)
            {"", 0}

          _ ->
            {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Server.run(["migrate", "--force"]) end)

      assert code == 0
      assert out =~ "restarted" or out =~ "Arbiter"
    end
  end

  # ---- other verbs ---------------------------------------------------------

  test "unknown subcommand errors with a usage hint" do
    {_out, err, code} = capture(fn -> Server.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown server subcommand"
  end

  test "no subcommand errors" do
    {_out, err, code} = capture(fn -> Server.run([]) end)
    assert code == 1
    assert err =~ "server requires a subcommand"
  end
end
