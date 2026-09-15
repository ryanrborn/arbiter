defmodule Arbiter.Sessions.OrphanReaperTest do
  @moduledoc """
  Kill-after-grace policy for orphan scopes (bd-3qkbch, RFC §4.6 item 1,
  phase 10).

  `decide/4` is asserted directly, with fakes, against the property that
  matters: an orphan first noticed this sweep is **never** in the kill list —
  only one that has survived a full grace window across repeated sweeps is.
  `sweep_once/2` is then exercised end-to-end against the injectable runner,
  the same seam `Arbiter.Sessions.Adoption` itself is tested through.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Arbiter.Sessions.OrphanReaper
  alias Arbiter.Test.SessionRunnerStub

  setup do
    runtime = Path.join(System.tmp_dir!(), "bd-3qkbch-or-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arbiter, :sessions_runtime_dir)
    Application.put_env(:arbiter, :sessions_runtime_dir, runtime)
    File.mkdir_p!(Path.join(runtime, "arbiter"))

    on_exit(fn ->
      if previous do
        Application.put_env(:arbiter, :sessions_runtime_dir, previous)
      else
        Application.delete_env(:arbiter, :sessions_runtime_dir)
      end

      File.rm_rf(runtime)
    end)

    SessionRunnerStub.reset()
    :ok
  end

  @unit "arb-session-orphan-1.scope"
  @orphan %{session_id: "orphan-1", unit: @unit, socket: nil}

  describe "decide/4 — the grace period" do
    test "an orphan seen for the first time is recorded, never killed" do
      now = DateTime.utc_now()

      assert {[], seen} = OrphanReaper.decide(%{}, [@orphan], now, 60 * 60_000)
      assert map_size(seen) == 1
    end

    test "an orphan still present after the grace window is killed" do
      now = DateTime.utc_now()
      {[], seen} = OrphanReaper.decide(%{}, [@orphan], now, 60 * 60_000)

      later = DateTime.add(now, 61, :minute)
      assert {[killed], updated_seen} = OrphanReaper.decide(seen, [@orphan], later, 60 * 60_000)
      assert killed == @orphan
      # Killing it clears its watch — a fresh sighting starts the clock over.
      assert updated_seen == %{}
    end

    test "an orphan still inside the grace window is not killed yet" do
      now = DateTime.utc_now()
      {[], seen} = OrphanReaper.decide(%{}, [@orphan], now, 60 * 60_000)

      soon = DateTime.add(now, 30, :minute)
      assert {[], seen_after} = OrphanReaper.decide(seen, [@orphan], soon, 60 * 60_000)
      assert map_size(seen_after) == 1
    end

    test "an orphan that stops appearing is dropped, not carried forward" do
      now = DateTime.utc_now()
      {[], seen} = OrphanReaper.decide(%{}, [@orphan], now, 60 * 60_000)

      later = DateTime.add(now, 61, :minute)
      assert {[], updated_seen} = OrphanReaper.decide(seen, [], later, 60 * 60_000)
      assert updated_seen == %{}
    end
  end

  describe "sweep_once/2 — end to end against the runner" do
    defp enumerate(live_units) do
      SessionRunnerStub.script(fn
        "systemctl", ["--user", "list-units" | _], _opts ->
          output =
            Enum.map_join(live_units, "", &"#{&1} loaded active running /usr/bin/tmux -S …\n")

          {output, 0}

        "tmux", ["-S", _socket, "has-session" | _], _opts ->
          {"no server running", 1}

        _cmd, _args, _opts ->
          {"", 0}
      end)
    end

    test "an orphan is reported but not killed on the sweep that first finds it" do
      enumerate([@unit])

      {result, seen} =
        with_log(fn ->
          OrphanReaper.sweep_once(%{}, runner: SessionRunnerStub, grace_ms: 3600_000)
        end)
        |> elem(0)

      assert [%{unit: @unit}] = result.orphans
      assert result.killed == []
      assert map_size(seen) == 1

      refute Enum.any?(SessionRunnerStub.calls("systemctl"), fn {_cmd, args, _} ->
               "stop" in args
             end)
    end

    test "the same orphan past its grace window is killed by exact unit/socket name" do
      enumerate([@unit])
      now = DateTime.utc_now()

      {_first, seen} =
        with_log(fn ->
          OrphanReaper.sweep_once(%{}, runner: SessionRunnerStub, grace_ms: 3600_000, now: now)
        end)
        |> elem(0)

      SessionRunnerStub.reset()
      later = DateTime.add(now, 61, :minute)

      {result, _seen} =
        with_log(fn ->
          OrphanReaper.sweep_once(seen, runner: SessionRunnerStub, grace_ms: 3600_000, now: later)
        end)
        |> elem(0)

      assert [%{unit: @unit}] = result.killed

      assert Enum.any?(SessionRunnerStub.calls("systemctl"), fn {_cmd, args, _} ->
               args == ["--user", "stop", @unit]
             end)
    end

    test "a session whose scope vanished with no client attached is ended, not just reaped as an orphan (bd-bsdeb2)" do
      {:ok, session} = Ash.create(Arbiter.Sessions.Session, %{cwd: "/tmp/work"})
      {:ok, session} = Arbiter.Sessions.mark_running(session)

      # No live units, no live sockets — the row's own scope is simply gone,
      # the same "exited with nobody watching" case a dead Stream process
      # would otherwise leave stuck at `:running` forever.
      enumerate([])

      {result, _seen} =
        with_log(fn ->
          OrphanReaper.sweep_once(%{}, runner: SessionRunnerStub, grace_ms: 3600_000)
        end)
        |> elem(0)

      assert result.orphans == []
      {:ok, reloaded} = Arbiter.Sessions.get(session.id)
      assert reloaded.status == :ended
      assert reloaded.mcp_token_revoked_at
    end

    test "a grace-expired orphan with an attached tmux client is held off, not killed" do
      {:ok, runtime} = Application.fetch_env(:arbiter, :sessions_runtime_dir)
      socket = Path.join(runtime, "arbiter/session-orphan-2.sock")
      File.write!(socket, "")

      SessionRunnerStub.script(fn
        "systemctl", ["--user", "list-units" | _], _opts ->
          {"", 0}

        "tmux", ["-S", ^socket, "has-session" | _], _opts ->
          {"", 0}

        "tmux", ["-S", ^socket, "list-clients" | _], _opts ->
          {"/dev/pts/3: coord [80x24]\n", 0}

        _cmd, _args, _opts ->
          {"", 0}
      end)

      now = DateTime.utc_now()

      {_first, seen} =
        with_log(fn ->
          OrphanReaper.sweep_once(%{}, runner: SessionRunnerStub, grace_ms: 3600_000, now: now)
        end)
        |> elem(0)

      later = DateTime.add(now, 61, :minute)

      {result, seen_after} =
        with_log(fn ->
          OrphanReaper.sweep_once(seen, runner: SessionRunnerStub, grace_ms: 3600_000, now: later)
        end)
        |> elem(0)

      assert result.killed == []
      assert [%{socket: ^socket}] = result.orphans
      # Held off, not dropped — it is re-checked on the next sweep.
      assert map_size(seen_after) == 1

      refute Enum.any?(SessionRunnerStub.calls("tmux"), fn {_cmd, args, _} ->
               "kill-session" in args
             end)
    end

    test "an enumeration failure touches no watched state" do
      SessionRunnerStub.script(fn
        "systemctl", _args, _opts -> {"Failed to connect to bus", 1}
        _cmd, _args, _opts -> {"", 0}
      end)

      seen_before = %{{:unit, @unit} => DateTime.utc_now()}

      {result, seen_after} =
        with_log(fn ->
          OrphanReaper.sweep_once(seen_before, runner: SessionRunnerStub, grace_ms: 3600_000)
        end)
        |> elem(0)

      assert result == %{orphans: [], killed: []}
      assert seen_after == seen_before
    end
  end

  describe "the periodic sweep's primary gate" do
    # `SessionRunnerStub`'s script lives in the *calling* process's dictionary
    # (see its moduledoc), and `sweep_once/2` here runs inside the GenServer's
    # own process — so these tests read the "skipped" log line as the signal
    # rather than tracking runner calls, which would need a cross-process
    # double to observe from here.
    test "a secondary instance's :sweep tick is skipped and logged" do
      {:ok, pid} =
        OrphanReaper.start_link(
          name: nil,
          enabled: false,
          runner: SessionRunnerStub,
          grace_ms: 3600_000,
          primary_check?: fn -> false end
        )

      log =
        with_log(fn ->
          send(pid, :sweep)
          _ = :sys.get_state(pid)
        end)
        |> elem(1)

      assert log =~ "not the primary instance"
    end

    test "a primary instance's :sweep tick runs the sweep, unskipped" do
      {:ok, pid} =
        OrphanReaper.start_link(
          name: nil,
          enabled: false,
          runner: SessionRunnerStub,
          grace_ms: 3600_000,
          primary_check?: fn -> true end
        )

      log =
        with_log(fn ->
          send(pid, :sweep)
          _ = :sys.get_state(pid)
        end)
        |> elem(1)

      refute log =~ "not the primary instance"
    end
  end
end
