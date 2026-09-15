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

    test "the generated instructions never carry the session's own token" do
      session = launch!()

      config = session.id |> Layout.mcp_config_path() |> File.read!() |> Jason.decode!()
      "Bearer " <> token = config["mcpServers"]["arbiter"]["headers"]["Authorization"]

      refute session.id |> Layout.instructions_path() |> File.read!() |> String.contains?(token)
    end
  end
end
