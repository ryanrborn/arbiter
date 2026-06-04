defmodule ArbiterCli.Cmd.UpdateDeployTest do
  # async: false — these tests mutate the global ARB_HOME env var and route
  # through the shared `:bd2_cmd_runner` / `:bd2_sleep` process-dict seams.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Update

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  setup do
    System.put_env("ARB_HOME", "/tmp/arbiter-update-test")
    System.delete_env("ARB_HOST")
    on_exit(fn -> System.delete_env("ARB_HOME") end)
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    :ok
  end

  # A cmd runner covering both the git preflight/pull and the reused restart
  # lifecycle. Knobs:
  #   * branch   — what `rev-parse --abbrev-ref HEAD` reports
  #   * dirty    — whether the tree has uncommitted changes
  #   * pull     — {output, exit_code} returned by `git pull --ff-only`
  #   * changed  — whether the pull advanced HEAD (drives before/after sha)
  # Records every invocation to the test pid as {:cmd, cmd, args}.
  defp stub_deploy(opts) do
    branch = Keyword.get(opts, :branch, "main")
    dirty = Keyword.get(opts, :dirty, false)
    pull = Keyword.get(opts, :pull, {"Updating aaaaaaa..bbbbbbb\n", 0})
    changed = Keyword.get(opts, :changed, true)
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {branch <> "\n", 0}

        {"git", ["status", "--porcelain"]} ->
          if dirty, do: {" M apps/foo/lib/foo.ex\n", 0}, else: {"", 0}

        {"git", ["rev-parse", "HEAD"]} ->
          if Process.get(:pulled), do: {"bbbbbbb\n", 0}, else: {"aaaaaaa\n", 0}

        {"git", ["pull", "--ff-only"]} ->
          {out, code} = pull
          if code == 0 and changed, do: Process.put(:pulled, true)
          {out, code}

        {"git", ["log" | _]} ->
          {"bbbbbbb merge feature two\nababab1 merge feature one\n", 0}

        # ---- reused restart lifecycle ----
        {"lsof", _} ->
          if Process.get(:terminated), do: {"", 1}, else: {"4242\n", 0}

        {"kill", _} ->
          Process.put(:terminated, true)
          {"", 0}

        {"sh", _} ->
          stub_get("/api/workspaces", @green)
          {"", 0}

        _ ->
          {"", 0}
      end
    end)
  end

  describe "deploy (no issue id)" do
    test "pulls new commits, restarts Phoenix, reports the short log, exits 0" do
      stub_get("/api/workspaces", @green)
      stub_deploy(changed: true)

      {out, _err, code} = capture(fn -> Update.run([]) end)

      assert code == 0
      assert out =~ "Pulled 2 new commit(s) onto main"
      assert out =~ "merge feature two"
      assert out =~ "Arbiter Phoenix restarted"
      assert out =~ "[ ok ] phoenix reachable"

      # Preflight, then pull, then the restart bounce.
      assert_received {:cmd, "git", ["rev-parse", "--abbrev-ref", "HEAD"]}
      assert_received {:cmd, "git", ["status", "--porcelain"]}
      assert_received {:cmd, "git", ["pull", "--ff-only"]}
      assert_received {:cmd, "sh", ["-c", script]}
      assert script =~ "mix phx.server"
    end

    test "--json emits a single object describing the pull and restart" do
      stub_get("/api/workspaces", @green)
      stub_deploy(changed: true)

      {out, _err, code} = capture(fn -> Update.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["pulled"] == true
      assert payload["restarted"] == true
      assert payload["ok"] == true
      assert payload["branch"] == "main"
      assert length(payload["commits"]) == 2
      assert payload["old_sha"] == "aaaaaaa"
      assert payload["new_sha"] == "bbbbbbb"
    end

    test "already up to date: skips the restart and exits 0" do
      stub_get("/api/workspaces", @green)
      stub_deploy(changed: false, pull: {"Already up to date.\n", 0})

      {out, _err, code} = capture(fn -> Update.run([]) end)

      assert code == 0
      assert out =~ "Already up to date"

      # Pulled, but never bounced the server.
      assert_received {:cmd, "git", ["pull", "--ff-only"]}
      refute_received {:cmd, "lsof", _}
      refute_received {:cmd, "sh", _}
    end
  end

  describe "deploy preflight aborts" do
    test "dirty working tree aborts before pulling, exit 1" do
      stub_get("/api/workspaces", @green)
      stub_deploy(dirty: true)

      {_out, err, code} = capture(fn -> Update.run([]) end)

      assert code == 1
      assert err =~ "uncommitted changes"
      refute_received {:cmd, "git", ["pull", "--ff-only"]}
    end

    test "off the integration branch aborts before pulling, exit 1" do
      stub_get("/api/workspaces", @green)
      stub_deploy(branch: "feature/wip")

      {_out, err, code} = capture(fn -> Update.run([]) end)

      assert code == 1
      assert err =~ "integration branch"
      refute_received {:cmd, "git", ["status", "--porcelain"]}
      refute_received {:cmd, "git", ["pull", "--ff-only"]}
    end

    test "non-fast-forward pull surfaces git's error, exit 1" do
      stub_get("/api/workspaces", @green)
      stub_deploy(pull: {"fatal: Not possible to fast-forward, aborting.\n", 1})

      {_out, err, code} = capture(fn -> Update.run([]) end)

      assert code == 1
      assert err =~ "fast-forward"
      refute_received {:cmd, "sh", _}
    end
  end

  describe "deploy timeout" do
    test "exits 1 when Phoenix never comes back green after the pull" do
      # Reachable during preflight, but the started server never goes green.
      stub_get("/api/workspaces", @green)
      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
        send(test_pid, {:cmd, cmd, args})

        case {cmd, args} do
          {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
            {"main\n", 0}

          {"git", ["status", "--porcelain"]} ->
            {"", 0}

          {"git", ["rev-parse", "HEAD"]} ->
            if Process.get(:pulled), do: {"bbbbbbb\n", 0}, else: {"aaaaaaa\n", 0}

          {"git", ["pull", "--ff-only"]} ->
            Process.put(:pulled, true)
            {"Updating\n", 0}

          {"git", ["log" | _]} ->
            {"bbbbbbb a commit\n", 0}

          {"lsof", _} ->
            if Process.get(:terminated), do: {"", 1}, else: {"7\n", 0}

          {"kill", _} ->
            Process.put(:terminated, true)
            {"", 0}

          # Note: deliberately does NOT flip the API to green on "sh".
          _ ->
            {"", 0}
        end
      end)

      stub_transport_error(:get, "/api/workspaces", :econnrefused)

      {out, _err, code} = capture(fn -> Update.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back up within 1s"
    end
  end

  describe "invocation routing" do
    test "an issue-edit flag without an id is steered, not silently deployed" do
      {_out, err, code} = capture(fn -> Update.run(["--priority", "0"]) end)

      assert code == 1
      assert err =~ "unknown option --priority"
      assert err =~ "arb update <id>"
    end

    test "a positional id still routes to the issue editor" do
      stub_patch(
        "/api/issues/bd-001",
        %{"id" => "bd-001", "title" => "X", "priority" => 0, "status" => "open"},
        200
      )

      {out, _err, code} = capture(fn -> Update.run(["bd-001", "--priority", "0"]) end)

      assert code == 0
      assert out =~ "bd-001"
      # No git/restart machinery was touched for an issue edit.
      refute_received {:cmd, "git", _}
    end
  end
end
