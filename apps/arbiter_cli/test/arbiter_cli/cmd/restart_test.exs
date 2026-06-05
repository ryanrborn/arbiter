defmodule ArbiterCli.Cmd.RestartTest do
  # async: false — these tests mutate the global ARB_HOME env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Restart

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}
  @no_polecats %{"data" => []}

  setup do
    # Deterministic project-root resolution; the shelled commands are stubbed
    # (see :bd2_cmd_runner) so the path need not actually exist.
    System.put_env("ARB_HOME", "/tmp/arbiter-restart-test")
    # Default port path — keep ARB_HOST off the default so api_port/0 parses 4848.
    System.delete_env("ARB_HOST")
    on_exit(fn -> System.delete_env("ARB_HOME") end)
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    # TCP port check seam: default to "port is free" so wait_port_free returns
    # immediately in tests without opening real sockets.
    Process.put(:bd2_port_check, fn _port -> true end)
    :ok
  end

  # A cmd runner that:
  #   * reports the given `pids` as the lsof listeners until SIGTERM is sent,
  #     then reports none (port freed);
  #   * makes the API reachable+green once Phoenix ("sh") is started.
  # Records every invocation to the test pid as {:cmd, cmd, args}.
  defp stub_lifecycle(pids) do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case cmd do
        "lsof" ->
          if Process.get(:terminated), do: {"", 1}, else: {Enum.join(pids, "\n") <> "\n", 0}

        "kill" ->
          Process.put(:terminated, true)
          {"", 0}

        "sh" ->
          stub_get("/api/workspaces", @green)
          {"", 0}

        _ ->
          {"", 0}
      end
    end)
  end

  describe "restart with a running server" do
    test "stops the listener, starts Phoenix, waits for green, exits 0" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      stub_lifecycle(["12345"])

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Stopped the previous server"
      assert out =~ "Arbiter Phoenix restarted"
      assert out =~ "[ ok ] phoenix reachable"

      # Found the listener, signalled it with TERM, then started Phoenix.
      assert_received {:cmd, "lsof", ["-ti", "tcp:4848", "-sTCP:LISTEN"]}
      assert_received {:cmd, "kill", ["-TERM", "12345"]}
      assert_received {:cmd, "sh", ["-c", script]}
      assert script =~ "mix phx.server"
    end

    test "--json reports stop + start actions and ok" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      stub_lifecycle(["999"])

      {out, _err, code} = capture(fn -> Restart.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["was_running"] == true
      assert payload["ok"] == true

      components = Enum.map(payload["actions"], & &1["component"])
      assert "phoenix_stop" in components
      assert "phoenix" in components

      stop = Enum.find(payload["actions"], &(&1["component"] == "phoenix_stop"))
      assert stop["status"] == "stopped"
      assert stop["pids"] == ["999"]
    end
  end

  describe "restart with nothing running" do
    test "starts a fresh server when no listener is found" do
      # API unreachable from the start; flips green once Phoenix is started.
      stub_transport_error(:get, "/api/workspaces", :econnrefused)

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          # No listener on the port.
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "No running server found"
      assert out =~ "Arbiter Phoenix restarted"
    end
  end

  describe "escalation to SIGKILL" do
    test "force-kills when SIGTERM doesn't free the port in time" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      test_pid = self()

      # lsof always reports the listener; SIGTERM never frees it, so the stop
      # loop times out and escalates. SIGKILL then "frees" it.
      # The port_free? seam flips to free only after SIGKILL.
      Process.put(:bd2_port_check, fn _port -> Process.get(:killed) == true end)

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case {cmd, args} do
          {"kill", ["-KILL" | _]} ->
            Process.put(:killed, true)
            {"", 0}

          {"lsof", _} ->
            if Process.get(:killed), do: {"", 1}, else: {"4242\n", 0}

          {"sh", _} ->
            stub_get("/api/workspaces", @green)
            {"", 0}

          _ ->
            {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run(["--timeout", "1"]) end)

      assert code == 0
      assert out =~ "Force-stopped the previous server"
      assert_received {:cmd, "kill", ["-TERM", "4242"]}
      assert_received {:cmd, "kill", ["-KILL", "4242"]}
    end
  end

  describe "lsof fallback" do
    test "uses ss when lsof is absent, then starts Phoenix normally" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case cmd do
          "lsof" ->
            raise ErlangError, original: :enoent

          "ss" ->
            # ss reports beam.smp pid=5678 listening
            {"LISTEN 0 128 0.0.0.0:4848 0.0.0.0:*  users:((\"beam.smp\",pid=5678,fd=20))\n", 0}

          "kill" ->
            {"", 0}

          "sh" ->
            stub_get("/api/workspaces", @green)
            {"", 0}

          _ ->
            {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Stopped the previous server"
      assert_received {:cmd, "ss", _}
      assert_received {:cmd, "kill", ["-TERM", "5678"]}
    end

    test "uses pgrep when both lsof and ss are absent, then starts Phoenix normally" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case cmd do
          "lsof" -> raise ErlangError, original: :enoent
          "ss" -> raise ErlangError, original: :enoent
          "pgrep" -> {"9999\n", 0}
          "kill" -> {"", 0}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Stopped the previous server"
      assert_received {:cmd, "pgrep", ["-f", "phx.server"]}
      assert_received {:cmd, "kill", ["-TERM", "9999"]}
    end

    test "proceeds as 'not running' when lsof, ss, and pgrep all find nothing" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" -> raise ErlangError, original: :enoent
          "ss" -> {"", 1}
          "pgrep" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "No running server found"
    end
  end

  describe "failures" do
    test "times out with exit 1 when Phoenix never comes back green" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      # Stop succeeds (port_free? returns true), but the started server never goes reachable.
      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" ->
            if Process.get(:terminated), do: {"", 1}, else: {"7\n", 0}

          "kill" ->
            Process.put(:terminated, true)
            {"", 0}

          # Note: deliberately does NOT flip the API to green on "sh".
          _ ->
            {"", 0}
        end
      end)

      stub_transport_error(:get, "/api/workspaces", :econnrefused)

      {out, _err, code} = capture(fn -> Restart.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back up within 1s"
      assert out =~ "[fail] phoenix reachable"
    end
  end

  describe "active-work guard" do
    test "refuses to restart when acolytes are actively working (no --force)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"},
         {%{"data" => [%{"bead_id" => "bd-abc", "status" => "running"}]}, 200}}
      ])

      {_out, err, code} = capture(fn -> Restart.run([]) end)

      assert code == 1
      assert err =~ "acolyte"
      assert err =~ "bd-abc"
      assert err =~ "--force"
    end

    test "--force proceeds even when acolytes are active" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"},
         {%{"data" => [%{"bead_id" => "bd-abc", "status" => "running"}]}, 200}}
      ])

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run(["--force"]) end)

      assert code == 0
      assert out =~ "Arbiter Phoenix restarted"
    end

    test "proceeds normally when no acolytes are active" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Arbiter Phoenix restarted"
    end

    test "proceeds when the server is unreachable (can't check polecats)" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Arbiter Phoenix restarted"
    end
  end

  describe "spawn working directory" do
    test "spawns Phoenix with cd set to the project root when .run-server.sh is absent" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args, opts})

        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      capture(fn -> Restart.run([]) end)

      assert_received {:cmd, "sh", ["-c", _script], opts}
      assert Keyword.get(opts, :cd) == "/tmp/arbiter-restart-test"
    end

    test "delegates to .run-server.sh when it exists in the project root" do
      arb_home = System.get_env("ARB_HOME")
      File.mkdir_p!(arb_home)
      run_sh = Path.join(arb_home, ".run-server.sh")
      File.write!(run_sh, "#!/bin/sh\nexec mix phx.server\n")
      on_exit(fn -> File.rm(run_sh) end)

      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args, opts})

        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      capture(fn -> Restart.run([]) end)

      assert_received {:cmd, "sh", ["-c", script], opts}
      assert script =~ ".run-server.sh"
      refute Keyword.has_key?(opts, :cd)
    end
  end

  describe "acolyte-session guard (bd-crqku8)" do
    test "refuses to restart when ARB_ACOLYTE_BEAD_ID is set" do
      System.put_env("ARB_ACOLYTE_BEAD_ID", "bd-test-acolyte")
      on_exit(fn -> System.delete_env("ARB_ACOLYTE_BEAD_ID") end)

      {_out, err, code} = capture(fn -> Restart.run([]) end)

      assert code == 1
      assert err =~ "acolyte session"
      assert err =~ "bd-test-acolyte"
    end

    test "proceeds normally when ARB_ACOLYTE_BEAD_ID is not set" do
      System.delete_env("ARB_ACOLYTE_BEAD_ID")

      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      Process.put(:bd2_cmd_runner, fn cmd, _args, _opts ->
        case cmd do
          "lsof" -> {"", 1}
          "sh" -> stub_get("/api/workspaces", @green) && {"", 0}
          _ -> {"", 0}
        end
      end)

      {out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert out =~ "Arbiter Phoenix restarted"
    end
  end

  describe "port resolution" do
    test "honors a custom ARB_HOST port" do
      System.put_env("ARB_HOST", "http://127.0.0.1:5005")
      on_exit(fn -> System.delete_env("ARB_HOST") end)

      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/polecats"}, {@no_polecats, 200}}
      ])

      stub_lifecycle(["321"])

      {_out, _err, code} = capture(fn -> Restart.run([]) end)

      assert code == 0
      assert_received {:cmd, "lsof", ["-ti", "tcp:5005", "-sTCP:LISTEN"]}
    end
  end
end
