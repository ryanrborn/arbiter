defmodule Arbiter.Sessions.ProvisioningTest do
  @moduledoc """
  The per-session provisioning scaffold (bd-aprlbb, RFC §9.1–§9.4, §8.1–§8.2,
  §10.2–§10.3).

  Acceptance criteria 1 (the §9.1 layout, and `launch/1` using it), 4 (both auth
  modes recorded, no credential material in argv / logs / the row) and 5 (the
  §10.2 mitigations, and a session cwd that is never inside the primary
  checkout).
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Provisioning
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  @token "sk-ant-oat01-PROVISIONING-TEST-TOKEN"

  setup do
    env = SessionEnv.sandbox("provisioning")
    SessionRunnerStub.reset()

    {:ok,
     root: env[:sessions_root],
     operator: env[:sessions_credentials_source],
     checkout: env[:primary_checkout]}
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.merge([runner: SessionRunnerStub], opts))
    session
  end

  defp tmp_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bd-o2vtsz-#{tag}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Same single-quote escaping `Arbiter.Sessions.Provisioning` uses internally
  # — asserted independently here (rather than by calling the private
  # function) so the test proves the *shape* an injection-safe quoting scheme
  # must have, not merely that the implementation agrees with itself.
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp session_settings!(session),
    do:
      session.id
      |> Layout.config_dir()
      |> Path.join("settings.json")
      |> File.read!()
      |> Jason.decode!()

  defp session_claude_json!(session),
    do:
      session.id
      |> Layout.config_dir()
      |> Path.join(".claude.json")
      |> File.read!()
      |> Jason.decode!()

  describe "the §9.1 layout (AC 1)" do
    test "creates the whole tree for a session id, and launch/1 uses it", %{root: root} do
      session = launch!()
      paths = Layout.paths(session.id)

      assert paths.root == Path.join(root, session.id)

      for dir <- [
            paths.root,
            paths.workspace,
            paths.config,
            paths.memory,
            paths.memory_shared,
            paths.memory_candidates,
            paths.transcript
          ] do
        assert File.dir?(dir), "expected #{dir} to exist"
      end

      assert File.regular?(paths.instructions)
      assert File.regular?(paths.mcp_config)
      assert File.regular?(paths.launch_script)

      # …and the row points at it, so the launcher and the sweep agree.
      assert session.root_dir == paths.root
      assert session.cwd == paths.workspace
      assert session.config_dir == paths.config
    end

    test "the pane runs the provisioned wrapper, cd'd into the scaffolded cwd" do
      session = launch!()
      script = Layout.launch_script_path(session.id)

      assert [{"systemd-run", args, _opts}] = SessionRunnerStub.calls()
      assert List.last(args) == script

      body = File.read!(script)
      assert body =~ "cd '#{Layout.workspace_dir(session.id)}'"
      assert body =~ "exec claude"
      assert {:ok, %{mode: mode}} = File.stat(script)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "no name supplied → launch.sh execs a bare claude, unchanged (bd-o2vtsz)" do
      session = launch!()
      body = File.read!(Layout.launch_script_path(session.id))

      assert body =~ "exec claude\n"
      refute body =~ "--name"
    end

    test "an operator-supplied name becomes claude --name <name>, single-quoted (bd-o2vtsz)" do
      session = launch!(name: "refinement session")
      body = File.read!(Layout.launch_script_path(session.id))

      assert body =~ "exec claude --name 'refinement session'\n"
    end

    test "a name with a quote, space, $ and ; is shell-quoted and injects nothing (bd-o2vtsz)" do
      bin_dir = tmp_dir!("stub-claude-bin")
      marker = Path.join(bin_dir, "injected-marker")
      capture = Path.join(bin_dir, "captured-argv")

      File.write!(Path.join(bin_dir, "claude"), """
      #!/bin/sh
      printf '%s\\n' "$@" > #{shell_quote(capture)}
      """)

      File.chmod!(Path.join(bin_dir, "claude"), 0o755)

      malicious = "o'Brien's $HOME; touch #{marker}"
      session = launch!(name: malicious)
      script = Layout.launch_script_path(session.id)

      body = File.read!(script)
      assert body =~ "exec claude --name " <> shell_quote(malicious) <> "\n"

      path = "#{bin_dir}:#{System.get_env("PATH")}"
      assert {_out, 0} = System.cmd("sh", [script], env: [{"PATH", path}], stderr_to_stdout: true)

      assert File.read!(capture) |> String.split("\n", trim: true) == ["--name", malicious]
      refute File.exists?(marker), "the ; inside the name must never run as a command"
    end

    test "only the §9.4 mount points ship — no promotion, no mounted layers yet" do
      session = launch!()

      assert File.ls!(Layout.memory_shared_dir(session.id)) == []
      assert File.ls!(Layout.memory_candidates_dir(session.id)) == []
    end

    test "re-provisioning an existing session is safe and preserves CLI state" do
      session = launch!()
      claude_json = Path.join(Layout.config_dir(session.id), ".claude.json")

      claude_json
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("bridgeOauthDeadExpiresAt", 123)
      |> Jason.encode!()
      |> then(&File.write!(claude_json, &1))

      assert {:ok, _} = Provisioning.provision(session)
      assert Jason.decode!(File.read!(claude_json))["bridgeOauthDeadExpiresAt"] == 123
    end
  end

  describe ".mcp.json (§9.3)" do
    test "declares the loopback MCP server with the session's bearer token" do
      session = launch!()

      config = session.id |> Layout.mcp_config_path() |> File.read!() |> Jason.decode!()
      server = config["mcpServers"]["arbiter"]

      assert server["type"] == "http"
      assert "Bearer " <> token = server["headers"]["Authorization"]
      assert {:ok, scope} = Arbiter.MCP.Scope.from_token(token)
      assert scope.session_id == session.id
    end

    test "is mode 0600 — it holds a live bearer token" do
      session = launch!()

      assert {:ok, %{mode: mode}} = File.stat(Layout.mcp_config_path(session.id))
      assert Bitwise.band(mode, 0o077) == 0
    end

    # Claude Code auto-loads `.mcp.json` from the working directory and nowhere
    # else, and `launch.sh` cd's into the session cwd before exec'ing the agent.
    # So this is asserted against `session.cwd`, not a literal path: a config one
    # directory out is a config the session never reads, and the session would
    # start with no Arbiter MCP server registered at all.
    test "sits in the session's cwd — the only place Claude Code loads it from" do
      session = launch!()
      in_cwd = Path.join(session.cwd, ".mcp.json")

      assert File.regular?(in_cwd)
      assert Layout.mcp_config_path(session.id) == in_cwd

      assert File.read!(Layout.launch_script_path(session.id)) =~
               "cd '#{Path.dirname(in_cwd)}'"

      refute File.exists?(Path.join(Layout.session_dir(session.id), ".mcp.json")),
             "a copy at the session root is a copy the agent never reads"
    end

    test "follows an overridden cwd", %{root: root} do
      cwd = Path.join(root, "elsewhere")
      File.mkdir_p!(cwd)

      session = launch!(cwd: cwd)

      assert session.cwd == cwd
      assert File.regular?(Path.join(cwd, ".mcp.json"))
      assert File.read!(Layout.launch_script_path(session.id)) =~ "cd '#{cwd}'"
      # And the generated instructions point the agent at the file that exists.
      assert session.id |> Layout.instructions_path() |> File.read!() =~
               Path.join(cwd, ".mcp.json")
    end
  end

  describe "auth modes (§8.1–§8.2, AC 4)" do
    test "mode B is the default, is recorded, and seeds the operator's credentials", %{
      operator: operator
    } do
      File.write!(
        Path.join(operator, ".credentials.json"),
        ~s({"claudeAiOauth":{"a":"#{@token}"}})
      )

      session = launch!(credentials_source: operator)
      assert session.auth_mode == :seeded_credentials

      seeded = Path.join(Layout.config_dir(session.id), ".credentials.json")
      assert File.read!(seeded) =~ @token
      # copied, never symlinked — both sides refresh the grant (§8.2)
      assert {:ok, %{type: :regular}} = File.lstat(seeded)
    end

    test "mode A is recorded and writes its token to a 0600 file, never to argv" do
      session = launch!(auth_mode: :oauth_token, oauth_token: @token)
      assert session.auth_mode == :oauth_token

      # Mode A must not also carry the operator's grant: two independent
      # refreshers of one refresh token rotate each other out (bd-6umoh9).
      refute File.exists?(Path.join(Layout.config_dir(session.id), ".credentials.json"))

      auth_env = Layout.auth_env_path(session.id)
      assert File.read!(auth_env) =~ @token
      assert {:ok, %{mode: mode}} = File.stat(auth_env)
      assert Bitwise.band(mode, 0o077) == 0

      # §10.3: /proc/<pid>/cmdline is world-readable on this host.
      assert [{"systemd-run", args, opts}] = SessionRunnerStub.calls()
      refute Enum.any?(args, &String.contains?(&1, @token))

      env = Keyword.get(opts, :env, [])
      refute Enum.any?(env, fn {_k, v} -> is_binary(v) and String.contains?(v, @token) end)
      refute Enum.any?(env, fn {k, _v} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
    end

    test "mode A without a token refuses to launch rather than launching unauthenticated" do
      log =
        capture_log(fn ->
          assert {:error, {:provisioning_failed, {:missing_oauth_token, _}}} =
                   Sessions.launch(
                     runner: SessionRunnerStub,
                     auth_mode: :oauth_token,
                     oauth_token: nil
                   )
        end)

      assert log =~ "provisioning failed"
      assert [session] = Sessions.list()
      assert session.status == :ended
      assert SessionRunnerStub.calls("systemd-run") == []
    end

    test "no credential material reaches the session row or the launch log" do
      log =
        capture_log(fn ->
          session = launch!(auth_mode: :oauth_token, oauth_token: @token)
          Process.put(:session, session)
        end)

      session = Process.get(:session)

      refute log =~ @token

      refute session
             |> Map.from_struct()
             |> Map.values()
             |> Enum.any?(&(is_binary(&1) and String.contains?(&1, @token)))
    end

    test "switching a session from mode A to mode B removes the stale auth file" do
      session = launch!(auth_mode: :oauth_token, oauth_token: @token)
      assert File.exists?(Layout.auth_env_path(session.id))

      {:ok, mode_b} = Ash.update(session, %{}, action: :mark_running)
      mode_b = %{mode_b | auth_mode: :seeded_credentials}

      assert {:ok, _} = Provisioning.provision(mode_b)
      refute File.exists?(Layout.auth_env_path(session.id))
    end
  end

  describe "§10.2 — reach into the primary checkout (AC 5)" do
    test "layer 1: the session cwd is never inside the primary checkout", %{checkout: checkout} do
      session = launch!()

      refute String.starts_with?(session.cwd, checkout <> "/")
      assert Layout.outside_primary_checkout?(session.cwd, checkout)
      assert Layout.outside_primary_checkout?(session.root_dir, checkout)
    end

    test "layer 1: a sessions root inside the checkout is refused, not silently used", %{
      checkout: checkout
    } do
      SessionEnv.override(sessions_root: Path.join(checkout, "sessions"))

      log =
        capture_log(fn ->
          assert {:error, {:provisioning_failed, {:inside_primary_checkout, _, _}}} =
                   Sessions.launch(runner: SessionRunnerStub)
        end)

      assert log =~ "never pointed at a checkout"
      assert SessionRunnerStub.calls("systemd-run") == []
    end

    test "a sibling directory sharing the checkout's prefix is not mistaken for a child" do
      assert Layout.outside_primary_checkout?(
               "/home/x/dev/arbiter-sessions",
               "/home/x/dev/arbiter"
             )

      refute Layout.outside_primary_checkout?("/home/x/dev/arbiter/apps", "/home/x/dev/arbiter")
      refute Layout.outside_primary_checkout?("/home/x/dev/arbiter", "/home/x/dev/arbiter")
    end

    test "layer 3: the session settings deny writes under the checkout", %{checkout: checkout} do
      session = launch!()

      settings =
        session.id
        |> Layout.config_dir()
        |> Path.join("settings.json")
        |> File.read!()
        |> Jason.decode!()

      assert "Write(#{checkout}/**)" in settings["permissions"]["deny"]
      assert "Edit(#{checkout}/**)" in settings["permissions"]["deny"]
    end

    test "layer 3 survives the bd-5xlkkj switch to auto mode", %{checkout: checkout} do
      session = launch!()
      settings = session_settings!(session)

      assert settings["permissions"]["defaultMode"] == "auto"
      assert "Write(#{checkout}/**)" in settings["permissions"]["deny"]
      assert "Bash(rm -rf:*)" in settings["permissions"]["deny"]
    end

    test "layer 4: the generated CLAUDE.md names the checkout and the worktree rule", %{
      checkout: checkout
    } do
      session = launch!()
      instructions = session.id |> Layout.instructions_path() |> File.read!()

      assert instructions =~ checkout
      assert instructions =~ "worktree"
      assert instructions =~ "pkill"
      # §9.4's read-only convention is enforced by this file and nothing else.
      assert instructions =~ "memory/candidates"
      assert instructions =~ "read-only"
    end

    # bd-5v8f8l — the role doctrine is prompt-only, so the one thing that can
    # break it is the file on disk not carrying it. `Arbiter.Sessions.Instructions`
    # is unit-tested; this is the production path that actually writes it.
    test "layer 4: the file a real launch writes carries the file-it-don't-fix-it rule" do
      session = launch!()
      instructions = session.id |> Layout.instructions_path() |> File.read!()

      assert instructions =~ "task_create"
      assert instructions =~ "Research discipline"
      # The worktree recipe is present but no longer the standing workflow.
      assert instructions =~ "worktree add"
      refute instructions =~ "the same discipline every dispatched worker follows"
    end

    test "the generated instructions never carry the session's own token" do
      session = launch!()

      config = session.id |> Layout.mcp_config_path() |> File.read!() |> Jason.decode!()
      "Bearer " <> token = config["mcpServers"]["arbiter"]["headers"]["Authorization"]

      refute session.id |> Layout.instructions_path() |> File.read!() |> String.contains?(token)
    end
  end

  # bd-5xlkkj — the post-merge live check of phase 5 watched a real first launch
  # stop on two prompts nobody was there to answer. These assert the *provisioned*
  # scaffold, not just the generator, because the bug was that provisioning never
  # passed the server name through.
  describe "first launch needs no operator click (bd-5xlkkj)" do
    test "pre-approves the MCP server it just wrote a .mcp.json for" do
      session = launch!()

      assert Arbiter.MCP.server_name() in session_settings!(session)["enabledMcpjsonServers"]

      project = session_claude_json!(session)["projects"][session.cwd]
      assert Arbiter.MCP.server_name() in project["enabledMcpjsonServers"]
    end

    test "writes no pre-approval for a session provisioned without MCP" do
      session = launch!(mcp: false)

      refute Map.has_key?(session_settings!(session), "enabledMcpjsonServers")
    end

    test "launches in auto mode with no bypass-warning to accept" do
      session = launch!()
      settings = session_settings!(session)

      assert settings["permissions"]["defaultMode"] == "auto"
      assert settings["skipAutoPermissionPrompt"] == true
      refute settings |> Jason.encode!() |> String.contains?("bypassPermissions")

      json = session_claude_json!(session)
      assert json["hasSeenAutoDefaultNotice"] == true
      assert json["hasSeenAutoModeEntryWarning"] == true
    end

    test "leaves Monitor and ScheduleWakeup available to the coordinator session" do
      session = launch!()
      deny = session_settings!(session)["permissions"]["deny"]

      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end
  end
end
