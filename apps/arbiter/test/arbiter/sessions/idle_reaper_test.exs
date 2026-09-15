defmodule Arbiter.Sessions.IdleReaperTest do
  @moduledoc """
  Idle-TTL sweep (bd-3qkbch, RFC §4.6 item 2, phase 10).

  Driven entirely through the injectable runner and an injectable clock:
  `reap/1` takes `:now`, so "idle past the TTL" is asserted by moving the
  clock forward rather than by racing real time.
  """
  use Arbiter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arbiter.Sessions
  alias Arbiter.Sessions.IdleReaper
  alias Arbiter.Sessions.Session
  alias Arbiter.Test.SessionRunnerStub

  setup do
    SessionRunnerStub.script(fn _cmd, _args, _opts -> {"", 0} end)
    SessionRunnerStub.reset()
    :ok
  end

  defp running_session! do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
    {:ok, session} = Sessions.mark_running(session)
    session
  end

  # Move a session's timestamp columns into the past directly — the same
  # backdating technique `Arbiter.Sessions.UsageIngestTest` uses, because
  # nothing in the public API accepts an explicit `started_at`/`last_client_at`
  # (by design: only the server clock writes them).
  defp backdate(session, attrs) do
    {1, _} =
      Arbiter.Repo.update_all(from(s in Session, where: s.id == ^session.id), set: attrs)

    {:ok, reloaded} = Sessions.get(session.id)
    reloaded
  end

  describe "reap/1" do
    test "a session idle past the TTL, with no activity beyond launch, is killed" do
      session = running_session!()
      old = DateTime.add(session.started_at, -25, :hour)
      backdate(session, started_at: old)

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, %{status: :ended, end_reason: reason}} = Sessions.get(session.id)
      assert reason =~ "idle timeout"
      assert reason =~ "keep_alive"
    end

    test "a recent client attach exempts a session, even with an old launch time" do
      session = running_session!()
      backdate(session, started_at: DateTime.add(session.started_at, -25, :hour))
      {:ok, session} = Sessions.touch_client(session)
      refute session.last_client_at == nil

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "a recent turn exempts a session the same way a client attach does" do
      session = running_session!()
      backdate(session, started_at: DateTime.add(session.started_at, -25, :hour))
      {:ok, session} = Sessions.touch_turn(session)
      refute session.last_turn_at == nil

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "keep_alive exempts a session no matter how stale its activity is" do
      session = running_session!()
      backdate(session, started_at: DateTime.add(session.started_at, -100, :hour))
      {:ok, session} = Sessions.set_keep_alive(session, true)
      assert session.keep_alive

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "a session inside the TTL window is left alone" do
      session = running_session!()
      backdate(session, started_at: DateTime.add(session.started_at, -1, :hour))

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "an already-ended session is never a candidate" do
      session = running_session!()
      {:ok, session} = Sessions.mark_ended(session, "already gone")
      backdate(session, started_at: DateTime.add(session.started_at, -100, :hour))

      assert :ok = IdleReaper.reap(idle_ttl_ms: 24 * 60 * 60_000, runner: SessionRunnerStub)

      assert {:ok, reloaded} = Sessions.get(session.id)
      assert reloaded.end_reason == "already gone"
    end
  end

  describe "last_activity/1" do
    test "picks the newest of last_client_at, last_turn_at, and started_at" do
      base = ~U[2026-01-01 00:00:00.000000Z]

      session = %Session{
        started_at: base,
        last_client_at: DateTime.add(base, 1, :hour),
        last_turn_at: DateTime.add(base, 2, :hour)
      }

      assert IdleReaper.last_activity(session) == DateTime.add(base, 2, :hour)
    end

    test "falls back to started_at when neither client nor turn timestamps exist" do
      base = ~U[2026-01-01 00:00:00.000000Z]
      session = %Session{started_at: base, last_client_at: nil, last_turn_at: nil}

      assert IdleReaper.last_activity(session) == base
    end
  end
end
