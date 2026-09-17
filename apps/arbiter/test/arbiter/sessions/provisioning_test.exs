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

    test "remote_control with a name: --remote-control gets <name> · <short-id>, injection-safe" do
      bin_dir = tmp_dir!("stub-claude-bin-remote")
      marker = Path.join(bin_dir, "injected-marker")
      capture = Path.join(bin_dir, "captured-argv")

      File.write!(Path.join(bin_dir, "claude"), """
      #!/bin/sh
      printf '%s\\n' "$@" > #{shell_quote(capture)}
      """)

      File.chmod!(Path.join(bin_dir, "claude"), 0o755)

      malicious = "o'Brien's $HOME; touch #{marker}"

      session =
        launch!(
          name: malicious,
          remote_control: true,
          bridge_verify_timeout_ms: 50,
          bridge_verify_poll_interval_ms: 10
        )

      short_id = String.slice(session.id, 0..7)
      combined = "#{malicious} · #{short_id}"
      script = Layout.launch_script_path(session.id)

      body = File.read!(script)

      assert body =~
               "exec claude --name " <>
                 shell_quote(malicious) <> " --remote-control " <> shell_quote(combined) <> "\n"

      path = "#{bin_dir}:#{System.get_env("PATH")}"
      assert {_out, 0} = System.cmd("sh", [script], env: [{"PATH", path}], stderr_to_stdout: true)

      # Verify the combined string arrived as a single argv entry and injected nothing
      argv = File.read!(capture) |> String.split("\n", trim: true)

      assert Enum.any?(argv, fn arg -> arg == combined end),
             "combined name · id must be a single argv entry"

      refute File.exists?(marker), "the ; inside the name must never run as a command"
    end

    test "remote_control: true appends --remote-control <id>, single-quoted (§8)" do
      session =
        launch!(
          remote_control: true,
          bridge_verify_timeout_ms: 50,
          bridge_verify_poll_interval_ms: 10
        )

      body = File.read!(Layout.launch_script_path(session.id))

      assert body =~ "exec claude --remote-control " <> shell_quote(session.id) <> "\n"
    end

    test "remote_control and a name both land, name first (§8, bd-o2vtsz)" do
      session =
        launch!(
          name: "afk session",
          remote_control: true,
          bridge_verify_timeout_ms: 50,
          bridge_verify_poll_interval_ms: 10
        )

      body = File.read!(Layout.launch_script_path(session.id))
      short_id = String.slice(session.id, 0..7)

      assert body =~
               "exec claude --name 'afk session' --remote-control " <>
                 shell_quote("afk session · #{short_id}") <> "\n"
    end

    test "no remote_control → launch.sh never mentions the flag" do
      session = launch!()
      body = File.read!(Layout.launch_script_path(session.id))

      refute body =~ "--remote-control"
    end

    test "no memory root configured → type-scoped shared dirs exist but stay empty" do
      session = launch!()

      shared = Layout.memory_shared_dir(session.id)
      assert File.ls!(shared) |> Enum.sort() == ~w(feedback project reference user)

      for type <- ~w(feedback project reference user),
          do: assert(File.ls!(Path.join(shared, type)) == [])

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

  describe "the §9.4 memory mounts (bd-6dkpf1, AC 1 and 3)" do
    defp write_memory_fixture!(root, filename, type, extra \\ "") do
      File.mkdir_p!(root)

      File.write!(Path.join(root, filename), """
      ---
      name: #{Path.rootname(filename)}
      description: fixture
      metadata:
        type: #{type}
      #{extra}---

      Fixture body.
      """)
    end

    test "launch/1 mounts user/feedback/reference for a cross-workspace session, and no project",
         %{root: root} do
      memory_root = Path.join(root, "memory")
      write_memory_fixture!(memory_root, "user-fact.md", "user")
      write_memory_fixture!(memory_root, "feedback-fact.md", "feedback")
      write_memory_fixture!(memory_root, "reference-fact.md", "reference")

      write_memory_fixture!(
        memory_root,
        "arbiter-internals.md",
        "project",
        "  workspace_id: ws-arbiter\n"
      )

      session = launch!(memory_root: memory_root)
      shared = Layout.memory_shared_dir(session.id)

      assert File.ls!(Path.join(shared, "user")) == ["user-fact.md"]
      assert File.ls!(Path.join(shared, "feedback")) == ["feedback-fact.md"]
      assert File.ls!(Path.join(shared, "reference")) == ["reference-fact.md"]
      assert File.ls!(Path.join(shared, "project")) == []
    end

    test "launch/1 scopes project memories to the session's bound workspace", %{root: root} do
      memory_root = Path.join(root, "memory")

      write_memory_fixture!(
        memory_root,
        "arbiter-internals.md",
        "project",
        "  workspace_id: ws-arbiter\n"
      )

      write_memory_fixture!(memory_root, "vstim-fact.md", "project", "  workspace_id: ws-vstim\n")

      session = launch!(memory_root: memory_root, workspace_id: "ws-vstim")
      shared = Layout.memory_shared_dir(session.id)

      assert File.ls!(Path.join(shared, "project")) == ["vstim-fact.md"]
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

    test "also writes the session's own token to $ARB_SESSION_ROOT/mcp_token (bd-5b5hq7)" do
      session = launch!()
      token_path = Layout.mcp_token_path(session.id)

      assert File.read!(token_path) |> String.trim() ==
               session.id
               |> Layout.mcp_config_path()
               |> File.read!()
               |> Jason.decode!()
               |> get_in(["mcpServers", "arbiter", "headers", "Authorization"])
               |> String.trim_leading("Bearer ")

      assert {:ok, %{mode: mode}} = File.stat(token_path)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "no mcp_token file when :mcp is disabled" do
      session = launch!(mcp: false)

      refute File.exists?(Layout.mcp_token_path(session.id))
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

  describe "the session's own event monitor (bd-aqafdr)" do
    test "writes a mode-0600 curl config carrying the session's bearer token" do
      session = launch!()
      curlrc = Layout.monitor_curlrc_path(session.id)

      contents = File.read!(curlrc)
      assert contents =~ ~r/^header = "Authorization: Bearer /m

      assert {:ok, %{mode: mode}} = File.stat(curlrc)
      assert Bitwise.band(mode, 0o077) == 0

      [_, token] = Regex.run(~r/Authorization: Bearer ([^\s"]+)/, contents)
      assert {:ok, scope} = Arbiter.MCP.Scope.from_token(token)
      assert scope.session_id == session.id
    end

    test "writes a mode-0700 monitor.sh that never calls arb mcp token mint and never puts the token in its own text" do
      session = launch!()
      script_path = Layout.monitor_script_path(session.id)

      script = File.read!(script_path)
      refute script =~ ~r/^[^#]*arb mcp token mint/m
      refute script =~ ~r/^\s*arb\s/m

      token =
        session.id
        |> Layout.mcp_token_path()
        |> File.read!()
        |> String.trim()

      refute script =~ token

      assert {:ok, %{mode: mode}} = File.stat(script_path)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "monitor.sh references the curl config and the /events route, not a bare token" do
      session = launch!()
      script = session.id |> Layout.monitor_script_path() |> File.read!()

      assert script =~ Layout.monitor_curlrc_path(session.id)
      assert script =~ "/events"
    end

    test "monitor.sh reconnects in a loop instead of exiting once its curl call ends" do
      session = launch!()
      script = session.id |> Layout.monitor_script_path() |> File.read!()

      assert script =~ ~r/while true; do/
      assert script =~ Layout.monitor_cursor_path(session.id)
      # the cursor file is read fresh on every loop iteration, not once up front
      assert script |> String.split(~r/while true; do/) |> Enum.at(1) =~ "CURSOR_FILE"
    end

    test "monitor.sh does not abort on a keepalive line (no bare `&&` under `set -e`)" do
      session = launch!()
      script = session.id |> Layout.monitor_script_path() |> File.read!()

      refute script =~ ~r/\]\s*&&\s*printf/
    end

    test "no monitor files when :mcp is disabled" do
      session = launch!(mcp: false)

      refute File.exists?(Layout.monitor_curlrc_path(session.id))
      refute File.exists?(Layout.monitor_script_path(session.id))
      refute File.exists?(Layout.monitor_cursor_path(session.id))
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

  # bd-980x89 — the refine variant renders into the cwd, as both files, rather
  # than the default single session-root `CLAUDE.md`.
  describe "the refine variant (task AC1)" do
    defp refine_opts do
      [
        refine: %{
          issue: %{
            id: "bd-refme01",
            title: "Fix the widget",
            description: "broken",
            acceptance: "fixed",
            issue_type: :bug,
            priority: 2,
            difficulty: 2,
            repo: "arbiter",
            refined: false,
            tracker_ref: nil
          },
          epic: nil,
          edges: [],
          repo_checkout: "/home/operator/dev/arbiter-readonly",
          workspace: nil
        }
      ]
    end

    test "writes CLAUDE.md and AGENTS.md into the cwd, not the session root" do
      session = launch!(refine_opts())

      claude_md = Path.join(session.cwd, "CLAUDE.md")
      agents_md = Path.join(session.cwd, "AGENTS.md")

      assert File.read!(claude_md) =~ "refine session"
      assert File.read!(agents_md) == File.read!(claude_md)

      # The default session-root CLAUDE.md is not written for a refine session.
      refute File.exists?(Layout.instructions_path(session.id))
    end

    test "a non-refine launch is unaffected — only the session-root CLAUDE.md exists" do
      session = launch!()

      refute File.exists?(Path.join(session.cwd, "CLAUDE.md"))
      refute File.exists?(Path.join(session.cwd, "AGENTS.md"))
      assert File.exists?(Layout.instructions_path(session.id))
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
