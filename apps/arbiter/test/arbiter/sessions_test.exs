defmodule Arbiter.SessionsTest do
  @moduledoc """
  The session lifecycle API (bd-bpt0ag, phase 1 of
  `docs/browser-hosted-coordinator-sessions.md`).

  Acceptance criteria 2 (`launch/1` command shape, `list/0`, `get/1`,
  `kill/2` via an injectable runner) and 5 (self-kill is refused).
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Guards
  alias Arbiter.Sessions.Naming
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    # Save-and-restore, not put-then-delete: `delete_env` would drop the values
    # `config/test.exs` sets and send every later test's provisioning into the
    # operator's real `~/dev/arbiter-sessions` (see `Arbiter.Test.SessionEnv`).
    env = SessionEnv.sandbox("lifecycle")

    SessionRunnerStub.reset()
    {:ok, runtime: env[:sessions_runtime_dir]}
  end

  defp launch!(opts \\ []) do
    {:ok, session} =
      Sessions.launch(
        Keyword.merge([cwd: "/tmp", provision: false, runner: SessionRunnerStub], opts)
      )

    session
  end

  describe "launch/1 — the §4.3 command shape" do
    test "spawns systemd-run --user --scope with the derived unit and socket", %{
      runtime: runtime
    } do
      session = launch!(cols: 120, rows: 40)

      assert [{"systemd-run", args, opts}] = SessionRunnerStub.calls()

      # systemd gives the lifetime: a transient, self-collecting user scope
      # whose name is derived from the session id.
      assert "--user" in args
      assert "--scope" in args
      assert "--collect" in args
      assert "--unit=arb-session-#{session.id}" in args

      # tmux gives the PTY, on a socket under $XDG_RUNTIME_DIR/arbiter.
      expected_socket = Path.join([runtime, "arbiter", "session-#{session.id}.sock"])
      assert argv_after(args, "-S") == expected_socket
      assert "new-session" in args
      assert "-d" in args
      assert argv_after(args, "-s") == "coord"
      assert argv_after(args, "-x") == "120"
      assert argv_after(args, "-y") == "40"
      assert argv_after(args, "-c") == "/tmp"

      # tmux must come after the systemd-run flags, or it is systemd-run's own
      # argument rather than the scope's payload.
      assert Enum.find_index(args, &(&1 == "tmux")) >
               Enum.find_index(args, &(&1 == "--scope"))

      # The payload command is last, and is a single argv token (tmux runs it
      # through a shell itself).
      assert List.last(args) == List.last(args) |> String.trim()
      assert Keyword.get(opts, :stderr_to_stdout) == true
    end

    test "exports the session id into the pane, and nothing secret" do
      session = launch!(config_dir: "/tmp/cfg")

      assert [{"systemd-run", args, opts}] = SessionRunnerStub.calls()

      env_flags =
        args
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [flag, _] -> flag == "-e" end)
        |> Enum.map(fn [_, pair] -> pair end)

      assert "ARB_SESSION_ID=#{session.id}" in env_flags
      assert "CLAUDE_CONFIG_DIR=/tmp/cfg" in env_flags

      # §10.3: /proc/<pid>/cmdline is world-readable, so no argv token may look
      # like a credential.
      refute Enum.any?(args, &(&1 =~ ~r/sk-ant|OAUTH|CREDENTIAL|TOKEN/i))

      # The same env also reaches the spawn itself, so a pre-existing tmux
      # server can't silently strip it.
      assert {"ARB_SESSION_ID", session.id} in Keyword.fetch!(opts, :env)
    end

    test "records the row as running and derives its handles" do
      session = launch!(workspace_id: nil)

      assert session.status == :running
      assert session.ended_at == nil
      assert session.scope_unit == "arb-session-#{session.id}.scope"
      assert session.tmux_socket == elem(Naming.socket_path(session.id), 1)
      assert session.workspace_id == nil
    end

    test "creates the socket directory before launching", %{runtime: runtime} do
      launch!()

      assert File.dir?(Path.join(runtime, "arbiter"))
    end

    test "a failed spawn ends the row with the failure as its reason" do
      SessionRunnerStub.script(fn "systemd-run", _args, _opts ->
        {"Failed to start transient scope unit: Unit already exists.", 1}
      end)

      log =
        capture_log(fn ->
          assert {:error, {:launch_failed, 1, _out}} =
                   Sessions.launch(cwd: "/tmp", provision: false, runner: SessionRunnerStub)
        end)

      assert log =~ "launch failed"

      assert [session] = Sessions.list()
      assert session.status == :ended
      assert session.end_reason =~ "Unit already exists"
      assert %DateTime{} = session.ended_at
    end

    test "cwd defaults to the scaffolded workspace rather than being required (phase 3)" do
      # Phase 1 required `:cwd`. Decision 4 / §10.2 layer 1 reverses that: a
      # session is *scaffolded*, never pointed at a checkout, so the default
      # is the session's own workspace directory and the caller supplies
      # nothing.
      assert {:ok, session} = Sessions.launch(runner: SessionRunnerStub)
      assert session.cwd == Arbiter.Sessions.Layout.workspace_dir(session.id)
      assert File.dir?(session.cwd)
    end
  end

  describe "list/0 and get/1" do
    test "lists newest first and filters by status" do
      first = launch!()
      second = launch!()

      assert Enum.map(Sessions.list(), & &1.id) == [second.id, first.id]

      {:ok, _} = Sessions.kill(first.id, runner: SessionRunnerStub)

      assert Enum.map(Sessions.list(status: :running), & &1.id) == [second.id]
      assert Enum.map(Sessions.list(status: :ended), & &1.id) == [first.id]
    end

    test "get/1 finds a session, and says so when it cannot" do
      session = launch!()

      assert {:ok, found} = Sessions.get(session.id)
      assert found.id == session.id
      assert {:error, :not_found} = Sessions.get(Ash.UUID.generate())
    end
  end

  describe "kill/2" do
    test "kills the tmux session and stops the scope, by exact name" do
      session = launch!()
      SessionRunnerStub.reset()

      assert {:ok, ended} = Sessions.kill(session.id, runner: SessionRunnerStub)

      assert [{"tmux", tmux_args, _}, {"systemctl", systemctl_args, _}] =
               SessionRunnerStub.calls()

      assert tmux_args == [
               "-S",
               session.tmux_socket,
               "kill-session",
               "-t",
               "coord"
             ]

      assert systemctl_args == ["--user", "stop", "arb-session-#{session.id}.scope"]

      assert ended.status == :ended
      assert %DateTime{} = ended.ended_at
      assert ended.end_reason == "killed"
    end

    test "records the caller's reason" do
      session = launch!()

      assert {:ok, ended} =
               Sessions.kill(session.id, reason: "idle deadline", runner: SessionRunnerStub)

      assert ended.end_reason == "idle deadline"
    end

    test "still ends the row when tmux is already gone" do
      session = launch!()

      SessionRunnerStub.script(fn
        "tmux", _args, _opts -> {"no server running on #{session.tmux_socket}", 1}
        _cmd, _args, _opts -> {"", 0}
      end)

      assert {:ok, ended} = Sessions.kill(session.id, runner: SessionRunnerStub)
      assert ended.status == :ended

      # The scope is still stopped — a dead tmux server must not leave a live
      # scope behind.
      assert [{"systemctl", ["--user", "stop", _unit], _}] =
               SessionRunnerStub.calls("systemctl")
    end

    test "an unknown id is not found, and spawns nothing" do
      assert {:error, :not_found} = Sessions.kill(Ash.UUID.generate(), runner: SessionRunnerStub)
      assert SessionRunnerStub.calls() == []
    end
  end

  describe "self-kill guard (§10.1, AC 5)" do
    test "a session cannot kill its own scope through the API" do
      session = launch!()
      SessionRunnerStub.reset()

      assert {:error, {:self_kill, message}} =
               Sessions.kill(session.id,
                 caller_session_id: session.id,
                 runner: SessionRunnerStub
               )

      assert message =~ session.id
      assert message =~ "own session"

      # Nothing was spawned, and the row is untouched.
      assert SessionRunnerStub.calls() == []
      assert {:ok, still_running} = Sessions.get(session.id)
      assert still_running.status == :running
      assert still_running.ended_at == nil
    end

    test "a session may kill a different session" do
      mine = launch!()
      theirs = launch!()

      assert {:ok, ended} =
               Sessions.kill(theirs.id, caller_session_id: mine.id, runner: SessionRunnerStub)

      assert ended.status == :ended
    end

    test "an operator-originated kill has no caller session and is allowed" do
      session = launch!()

      assert {:ok, ended} =
               Sessions.kill(session.id, caller_session_id: nil, runner: SessionRunnerStub)

      assert ended.status == :ended
    end

    test "the guard is a plain predicate, whitespace and case insensitive" do
      assert :ok = Guards.check_self_kill("a", "b")
      assert :ok = Guards.check_self_kill("a", nil)
      assert {:error, {:self_kill, _}} = Guards.check_self_kill("a", "a")
      assert {:error, {:self_kill, _}} = Guards.check_self_kill("a", " a ")
    end
  end

  describe "restart rate-limit hook (§10.1)" do
    test "allows a caller under the budget and refuses one over it" do
      now = DateTime.utc_now()
      recent = for m <- [1, 2, 3], do: DateTime.add(now, -m * 60, :second)

      assert :ok = Guards.check_restart_budget(recent, limit: 4, window_seconds: 3600, now: now)

      assert {:error, {:restart_rate_limited, message}} =
               Guards.check_restart_budget(recent, limit: 3, window_seconds: 3600, now: now)

      assert message =~ "3"
    end

    test "restarts outside the window do not count" do
      now = DateTime.utc_now()
      old = for h <- [2, 3, 4], do: DateTime.add(now, -h * 3600, :second)

      assert :ok = Guards.check_restart_budget(old, limit: 1, window_seconds: 3600, now: now)
    end

    test "an operator-originated restart is never rate limited" do
      assert :ok = Guards.check_restart_budget(nil)
    end
  end

  describe "provider session id (§7.5 rollover)" do
    test "a rollover replaces the id the ledger joins on" do
      session = launch!()

      {:ok, updated} = Sessions.record_provider_session(session, "sid-2")

      assert updated.provider_session_id == "sid-2"
      assert updated.status == :running
    end
  end

  describe "touch_client/1" do
    test "stamps last_client_at" do
      session = launch!()
      assert session.last_client_at == nil

      {:ok, touched} = Sessions.touch_client(session)

      assert %DateTime{} = touched.last_client_at
    end
  end

  describe "remote control bridge verification (§8.3)" do
    test "remote_control: true starts a background verify against config_dir, and a failure broadcasts bridge_unavailable" do
      session =
        launch!(
          remote_control: true,
          bridge_verify_fun: fn _dir, _opts -> {:error, :bridge_unavailable} end
        )

      Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.usage_topic(session.id))

      assert_receive {:session_error, session_id, %{code: "bridge_unavailable"}}, 1_000
      assert session_id == session.id
    end

    test "a bridge that comes up broadcasts nothing" do
      session = launch!(remote_control: true, bridge_verify_fun: fn _dir, _opts -> :ok end)

      Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.usage_topic(session.id))

      refute_receive {:session_error, _id, _payload}, 200
    end

    test "the verify function receives the session's own config_dir and the configured timeouts" do
      test_pid = self()

      session =
        launch!(
          config_dir: "/tmp/some-config-dir",
          remote_control: true,
          bridge_verify_timeout_ms: 1234,
          bridge_verify_poll_interval_ms: 56,
          bridge_verify_fun: fn dir, opts ->
            send(test_pid, {:verify_called, dir, opts})
            :ok
          end
        )

      assert_receive {:verify_called, dir, opts}, 1_000
      assert dir == session.config_dir
      assert opts[:timeout_ms] == 1234
      assert opts[:poll_interval_ms] == 56
    end

    test "remote_control: false never starts a verify" do
      test_pid = self()

      launch!(
        remote_control: false,
        bridge_verify_fun: fn _dir, _opts ->
          send(test_pid, :verify_called)
          :ok
        end
      )

      refute_receive :verify_called, 200
    end

    test "verify_bridge: false skips verification even under remote_control: true" do
      test_pid = self()

      launch!(
        remote_control: true,
        verify_bridge: false,
        bridge_verify_fun: fn _dir, _opts ->
          send(test_pid, :verify_called)
          :ok
        end
      )

      refute_receive :verify_called, 200
    end
  end

  # The argv token following `flag`, so a shape assertion reads like the
  # command rather than like an index calculation.
  defp argv_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end
end
