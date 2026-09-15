defmodule Arbiter.Sessions.AdoptionTest do
  @moduledoc """
  Boot-time adoption sweep (bd-bpt0ag, RFC §4.6 item 1) — acceptance
  criterion 4.

  The sweep is the *only* thing that reconnects Arbiter to sessions after
  `systemctl --user restart arbiter`, because nothing in the BEAM holds a
  handle to them. Its three obligations:

    1. re-adopt rows whose scope (or tmux socket) is still live;
    2. mark rows whose scope has vanished as ended, **with a reason**;
    3. never kill a live scope it does not recognise — report it instead.

  Driven entirely through the injectable runner, which stands in as the fake
  `systemctl` / `tmux` enumerator.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Adoption
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session
  alias Arbiter.Test.SessionRunnerStub

  setup do
    runtime = Path.join(System.tmp_dir!(), "bd-bpt0ag-ad-#{System.unique_integer([:positive])}")
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
    {:ok, runtime: runtime}
  end

  # A row written the way `launch/1` writes one, without launching anything.
  defp session_row!(status) do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})

    case status do
      :running -> Sessions.mark_running(session) |> elem(1)
      :starting -> session
      :ended -> Sessions.mark_ended(session, "already gone") |> elem(1)
    end
  end

  # What `systemctl --user list-units 'arb-session-*' --no-legend --plain`
  # prints: UNIT LOAD ACTIVE SUB DESCRIPTION.
  defp list_units_output(units) do
    units
    |> Enum.map(&"#{&1} loaded active running /usr/bin/tmux -S … new-session\n")
    |> Enum.join()
  end

  defp enumerate(live_units, live_sockets \\ []) do
    SessionRunnerStub.script(fn
      "systemctl", ["--user", "list-units" | _], _opts ->
        {list_units_output(live_units), 0}

      "tmux", ["-S", socket, "has-session" | _], _opts ->
        if socket in live_sockets, do: {"", 0}, else: {"no server running", 1}

      _cmd, _args, _opts ->
        {"", 0}
    end)
  end

  describe "sweep/1 — re-adoption" do
    test "a row whose scope is still live is re-adopted" do
      session = session_row!(:running)
      enumerate([session.scope_unit])

      assert {:ok, result} = Adoption.sweep(runner: SessionRunnerStub)

      assert result.adopted == [session.id]
      assert result.ended == []
      assert result.orphans == []

      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.status == :running
      assert reloaded.ended_at == nil
    end

    test "a row still :starting when the server died is adopted if its scope came up" do
      session = session_row!(:starting)
      enumerate([session.scope_unit])

      assert {:ok, %{adopted: [id]}} = Adoption.sweep(runner: SessionRunnerStub)
      assert id == session.id

      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.status == :running
    end

    test "a live tmux socket alone is enough to keep a row" do
      session = session_row!(:running)
      File.write!(session.tmux_socket, "")
      # No scope unit listed — only the socket answers.
      enumerate([], [session.tmux_socket])

      assert {:ok, %{adopted: [id], ended: []}} = Adoption.sweep(runner: SessionRunnerStub)
      assert id == session.id
    end
  end

  describe "sweep/1 — vanished scopes" do
    test "a row with no scope and no socket is ended, with a reason" do
      session = session_row!(:running)
      enumerate([])

      assert {:ok, result} = Adoption.sweep(runner: SessionRunnerStub)

      assert result.ended == [session.id]
      assert result.adopted == []

      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.status == :ended
      assert %DateTime{} = reloaded.ended_at
      assert reloaded.end_reason =~ "scope"
      assert reloaded.end_reason =~ "adoption sweep"
    end

    test "an already-ended row is left alone" do
      ended = session_row!(:ended)
      enumerate([])

      assert {:ok, %{adopted: [], ended: [], orphans: []}} =
               Adoption.sweep(runner: SessionRunnerStub)

      assert {:ok, reloaded} = Sessions.get(ended.id)
      assert reloaded.end_reason == "already gone"
    end

    test "the sweep is idempotent" do
      session = session_row!(:running)
      enumerate([])

      assert {:ok, %{ended: [_]}} = Adoption.sweep(runner: SessionRunnerStub)
      assert {:ok, %{ended: [], adopted: []}} = Adoption.sweep(runner: SessionRunnerStub)

      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.end_reason =~ "adoption sweep"
    end
  end

  describe "sweep/1 — unknown live scopes are never killed" do
    test "an unrecognised live scope is reported and logged, not stopped" do
      unknown = "arb-session-#{Ash.UUID.generate()}.scope"
      enumerate([unknown])

      log =
        capture_log(fn ->
          assert {:ok, result} = Adoption.sweep(runner: SessionRunnerStub)

          assert [orphan] = result.orphans
          assert orphan.unit == unknown
          assert orphan.session_id == Naming.session_id_from_unit(unknown)
        end)

      assert log =~ "orphan"
      assert log =~ unknown

      # The whole point: no stop, no kill, for a scope we do not recognise.
      assert SessionRunnerStub.calls("systemctl")
             |> Enum.all?(fn {_cmd, args, _} -> "stop" not in args end)

      refute Enum.any?(SessionRunnerStub.calls("tmux"), fn {_cmd, args, _} ->
               "kill-session" in args or "kill-server" in args
             end)
    end

    test "a live scope whose row was deliberately ended is an orphan, not a re-adoption" do
      ended = session_row!(:ended)
      enumerate([ended.scope_unit])

      assert {:ok, result} = capture_orphans()

      assert result.adopted == []
      assert [%{session_id: id}] = result.orphans
      assert id == ended.id

      assert {:ok, reloaded} = Sessions.get(ended.id)
      assert reloaded.status == :ended
    end

    test "a live socket with no row at all is reported too", %{runtime: runtime} do
      orphan_id = Ash.UUID.generate()
      socket = Path.join([runtime, "arbiter", "session-#{orphan_id}.sock"])
      File.write!(socket, "")
      enumerate([], [socket])

      assert {:ok, result} = capture_orphans()

      assert [%{session_id: ^orphan_id, socket: ^socket}] = result.orphans
    end
  end

  describe "sweep/1 — degraded hosts" do
    test "a systemctl that is not there does not end every row" do
      session = session_row!(:running)

      SessionRunnerStub.script(fn
        "systemctl", _args, _opts -> {"Failed to connect to bus: No such file or directory", 1}
        _cmd, _args, _opts -> {"", 0}
      end)

      log =
        capture_log(fn ->
          assert {:error, {:enumerate_failed, _}} = Adoption.sweep(runner: SessionRunnerStub)
        end)

      assert log =~ "could not enumerate"

      # Critically: the rows are untouched. A sweep that cannot see the host
      # must not conclude that everything died.
      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.status == :running
      assert reloaded.ended_at == nil
    end
  end

  # The orphan branch always logs a warning; swallow it so the assertion output
  # stays readable while still returning the sweep result.
  defp capture_orphans do
    {result, _log} = with_log(fn -> Adoption.sweep(runner: SessionRunnerStub) end)
    result
  end
end
