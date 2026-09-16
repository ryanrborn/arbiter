defmodule Arbiter.Sessions.TranscriptRetentionTest do
  @moduledoc """
  Retention sweep for persisted raw transcripts (§11, phase 9). Driven with
  an explicit `:now`, the same technique `Arbiter.Sessions.IdleReaperTest`
  uses, so "past the retention window" is asserted by moving the clock
  rather than racing real time.
  """
  use Arbiter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Sessions.TranscriptRetention

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, tmp_dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:arbiter, :sessions_root, previous)
    end)

    :ok
  end

  @moduletag :tmp_dir

  defp ended_session! do
    {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
    {:ok, session} = Sessions.mark_running(session)
    {:ok, session} = Sessions.mark_ended(session, "test")
    session
  end

  defp backdate_ended_at(session, ended_at) do
    {1, _} =
      Arbiter.Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [ended_at: ended_at]
      )

    {:ok, reloaded} = Sessions.get(session.id)
    reloaded
  end

  describe "sweep/1" do
    test "deletes the transcript of a session ended past the retention window" do
      session = ended_session!()
      :ok = Transcript.append(session.id, "hello")
      old = DateTime.add(DateTime.utc_now(), -31, :day)
      session = backdate_ended_at(session, old)

      assert :ok = TranscriptRetention.sweep(retention_days: 30)

      refute File.exists?(Transcript.path_for(session.id))
    end

    test "leaves a transcript within the retention window alone" do
      session = ended_session!()
      :ok = Transcript.append(session.id, "hello")
      recent = DateTime.add(DateTime.utc_now(), -1, :day)
      session = backdate_ended_at(session, recent)

      assert :ok = TranscriptRetention.sweep(retention_days: 30)

      assert File.exists?(Transcript.path_for(session.id))
    end

    test "a still-running session's transcript is never touched" do
      {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work"})
      {:ok, session} = Sessions.mark_running(session)
      :ok = Transcript.append(session.id, "hello")

      assert :ok = TranscriptRetention.sweep(retention_days: 0)

      assert File.exists?(Transcript.path_for(session.id))
    end

    test "a session with no captured transcript is a no-op" do
      session = ended_session!()
      old = DateTime.add(DateTime.utc_now(), -31, :day)
      backdate_ended_at(session, old)

      assert :ok = TranscriptRetention.sweep(retention_days: 30)
    end
  end
end
