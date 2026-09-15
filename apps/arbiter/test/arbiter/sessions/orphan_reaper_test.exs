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
end
