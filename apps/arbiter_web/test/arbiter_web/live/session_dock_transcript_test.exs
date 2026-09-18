defmodule ArbiterWeb.SessionDockTranscriptTest do
  @moduledoc """
  The dock window of a session that ended *before this browser session*
  (bd-3tf4oo, #1818).

  Before this, that window rendered an empty panel. Now it either replays the
  persisted raw transcript read-only — through the same terminal hook and the
  same channel a live pane uses — or says, in as many words, why there is
  nothing to replay. What it never does is look live: no status strip, no
  input, no reconnect.
  """
  use ArbiterWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Worker.SessionArchive

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-dock-transcript")
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  defp ended_session!(opts \\ []) do
    {:ok, session} = Sessions.launch(runner: NoopRunner, ensure_reader: false)

    case Keyword.get(opts, :transcript) do
      nil -> :ok
      bytes -> :ok = Transcript.append(session.id, bytes)
    end

    {:ok, ended} = Sessions.kill(session.id)
    ended
  end

  defp dock(conn) do
    {:ok, view, _html} = live(conn, "/")
    find_live_child(view, "session-dock")
  end

  defp open!(dock, session) do
    render_click(element(dock, "#session-dock-roster-toggle"))
    render_click(element(dock, "#session-dock-open-#{session.id}"))
    dock
  end

  describe "an ended session with a persisted transcript" do
    setup %{conn: conn} do
      session = ended_session!(transcript: "\e[32mhello from the agent\e[0m\r\n")
      %{session: session, dock: open!(dock(conn), session)}
    end

    test "mounts the terminal in transcript mode, read-only", %{dock: dock, session: session} do
      assert has_element?(
               dock,
               ~s(#session-dock-terminal-#{session.id}[data-transcript="true"][data-readonly="true"])
             )
    end

    test "does not render the unavailable state", %{dock: dock, session: session} do
      refute has_element?(dock, "#session-dock-unavailable-#{session.id}")
    end

    test "renders no live status strip", %{dock: dock, session: session} do
      refute has_element?(dock, "#session-dock-status-#{session.id}")
    end

    test "says the pane is a replay, read-only", %{dock: dock, session: session} do
      assert has_element?(dock, "#session-dock-ended-#{session.id}", "read-only")
      assert has_element?(dock, "#session-dock-ended-#{session.id}", "transcript")
    end

    test "puts the end reason and the ended-at time in the title bar", %{
      dock: dock,
      session: session
    } do
      assert has_element?(dock, "#session-dock-end-reason-#{session.id}", session.end_reason)

      assert has_element?(
               dock,
               "#session-dock-ended-at-#{session.id}",
               Calendar.strftime(session.ended_at, "%Y-%m-%d %H:%M")
             )
    end

    test "offers the whole file as a download", %{dock: dock, session: session} do
      assert has_element?(
               dock,
               ~s(#session-dock-transcript-download-#{session.id}[href="/sessions/#{session.id}/transcript"])
             )
    end

    test "says nothing about showing only part of it", %{dock: dock, session: session} do
      refute has_element?(dock, "#session-dock-transcript-truncated-#{session.id}")
    end
  end

  describe "a transcript over the replay cap" do
    setup %{conn: conn} do
      put_env(:sessions_transcript, replay_max_bytes: 64)
      session = ended_session!(transcript: String.duplicate("x", 500))
      %{session: session, dock: open!(dock(conn), session)}
    end

    test "says how much of it is on screen", %{dock: dock, session: session} do
      assert has_element?(dock, "#session-dock-transcript-truncated-#{session.id}", "last")
    end

    test "still offers the whole file", %{dock: dock, session: session} do
      assert has_element?(dock, "#session-dock-transcript-download-#{session.id}")
    end

    test "still mounts the pane", %{dock: dock, session: session} do
      assert has_element?(dock, ~s(#session-dock-terminal-#{session.id}[data-transcript="true"]))
    end
  end

  describe "an ended session with no transcript" do
    test "a session that was never captured says so, and mounts no terminal", %{conn: conn} do
      session = ended_session!()
      dock = open!(dock(conn), session)

      assert has_element?(
               dock,
               ~s(#session-dock-unavailable-#{session.id}[data-reason="never_captured"])
             )

      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
    end

    test "a transcript the retention sweep deleted says so", %{conn: conn} do
      session = ended_session!()

      backdate_ended_at!(
        session,
        DateTime.add(DateTime.utc_now(), -(Transcript.retention_days() + 1), :day)
      )

      dock = open!(dock(conn), session)

      assert has_element?(
               dock,
               ~s(#session-dock-unavailable-#{session.id}[data-reason="retention_deleted"])
             )
    end

    test "an empty capture file is not replayed as a transcript", %{conn: conn} do
      session = ended_session!()
      File.mkdir_p!(Path.dirname(Transcript.path_for(session.id)))
      File.write!(Transcript.path_for(session.id), "")

      dock = open!(dock(conn), session)

      assert has_element?(dock, ~s(#session-dock-unavailable-#{session.id}[data-reason="empty"]))
    end

    test "links the archived session JSONL when there is one", %{conn: conn} do
      session = ended_session!()
      archive!(session.id)

      dock = open!(dock(conn), session)

      assert has_element?(
               dock,
               ~s(#session-dock-jsonl-#{session.id}[href="/sessions/#{session.id}/jsonl"][download="#{session.id}.jsonl"])
             )
    end

    test "links no JSONL when nothing was archived", %{conn: conn} do
      session = ended_session!()
      dock = open!(dock(conn), session)

      refute has_element?(dock, "#session-dock-jsonl-#{session.id}")
    end
  end

  describe "a running session is untouched" do
    test "its window still mounts a live pane, not a transcript", %{conn: conn} do
      {:ok, session} = Sessions.launch(runner: NoopRunner, ensure_reader: false)
      :ok = Transcript.append(session.id, "live output")

      dock = open!(dock(conn), session)

      assert has_element?(dock, "#session-dock-status-#{session.id}")
      refute has_element?(dock, ~s(#session-dock-terminal-#{session.id}[data-transcript="true"]))
      refute has_element?(dock, "#session-dock-ended-#{session.id}")
    end
  end

  # The retention sweep deletes a transcript once the session has been over
  # longer than the window, so "swept" is a row whose `ended_at` is that old.
  defp backdate_ended_at!(session, ended_at) do
    {1, _} =
      Arbiter.Repo.update_all(
        from(row in Arbiter.Sessions.Session, where: row.id == ^session.id),
        set: [ended_at: ended_at]
      )

    :ok
  end

  defp archive!(session_id) do
    path = SessionArchive.path_for(session_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :zlib.gzip(~s({"type":"user"}\n)))
    on_exit(fn -> File.rm(path) end)
  end
end
