defmodule ArbiterWeb.SessionTranscriptControllerTest do
  @moduledoc """
  Downloading a finished session's artefacts (bd-3tf4oo): the whole raw
  transcript the dock only replays the tail of, and the archived session JSONL
  the unavailable state — and the issue detail page's "Transcript" link
  (bd-cvfjms) — point at when one exists.

  Loopback-only, the same rule `ArbiterWeb.SessionSocket` applies to the
  terminal itself (§10.4) — these bytes are the session's screen and its
  agent transcript.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Worker.SessionArchive

  setup do
    Arbiter.Test.SessionEnv.sandbox("transcript-download")
    {:ok, session} = Sessions.launch(runner: NoopRunner, ensure_reader: false)
    {:ok, ended} = Sessions.kill(session.id)
    %{session: ended}
  end

  defp off_box(conn), do: %{conn | remote_ip: {203, 0, 113, 7}}

  describe "GET /sessions/:id/transcript" do
    test "serves the whole raw transcript", %{conn: conn, session: session} do
      :ok = Transcript.append(session.id, String.duplicate("z", 4096))

      conn = get(conn, ~p"/sessions/#{session.id}/transcript")

      assert conn.status == 200
      assert response_content_type(conn, :txt) =~ "text/plain"
      assert conn.resp_body == String.duplicate("z", 4096)

      assert {"content-disposition", disposition} =
               List.keyfind(conn.resp_headers, "content-disposition", 0)

      assert disposition =~ "#{session.id}.raw"
    end

    test "404s when there is no transcript", %{conn: conn, session: session} do
      conn = get(conn, ~p"/sessions/#{session.id}/transcript")

      assert conn.status == 404
    end

    test "404s for a session that does not exist", %{conn: conn} do
      conn = get(conn, ~p"/sessions/#{Ash.UUID.generate()}/transcript")

      assert conn.status == 404
    end

    test "refuses an id that is not a session id at all", %{conn: conn} do
      conn = get(conn, "/sessions/#{URI.encode_www_form("../../../etc/passwd")}/transcript")

      assert conn.status == 404
    end

    test "refuses a 16-byte path-traversal id (Ecto.UUID's raw-binary cast clause)", %{conn: conn} do
      # "../../../../../x" is exactly 16 bytes, which `Ecto.UUID.cast/1`
      # accepts via its raw-binary clause and re-encodes as a harmless-looking
      # hex UUID. The served path must come from the looked-up row, never from
      # the original string, or this reaches the filesystem outside the root.
      traversal = "../../../../../x"
      assert byte_size(traversal) == 16

      conn = get(conn, "/sessions/" <> URI.encode(traversal, &(&1 != ?/)) <> "/transcript")

      assert conn.status == 404
    end

    test "refuses an off-box peer", %{conn: conn, session: session} do
      :ok = Transcript.append(session.id, "secret output")

      conn = get(off_box(conn), ~p"/sessions/#{session.id}/transcript")

      assert conn.status == 403
      refute conn.resp_body =~ "secret output"
    end
  end

  describe "GET /sessions/:id/jsonl" do
    test "serves the archived session JSONL, decompressed", %{conn: conn, session: session} do
      archive!(session.id, ~s({"type":"assistant","text":"hello"}\n))

      conn = get(conn, ~p"/sessions/#{session.id}/jsonl")

      assert conn.status == 200
      assert conn.resp_body == ~s({"type":"assistant","text":"hello"}\n)

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="#{session.id}.jsonl")
             ]
    end

    test "404s when nothing was archived", %{conn: conn, session: session} do
      conn = get(conn, ~p"/sessions/#{session.id}/jsonl")

      assert conn.status == 404
    end

    test "404s on a path-traversal id instead of reading the filesystem", %{conn: conn} do
      conn = get(conn, "/sessions/..%2F..%2F..%2Fetc%2Fpasswd/jsonl")

      assert conn.status == 404
    end

    test "refuses an off-box peer", %{conn: conn, session: session} do
      archive!(session.id, ~s({"type":"assistant","text":"secret"}\n))

      conn = get(off_box(conn), ~p"/sessions/#{session.id}/jsonl")

      assert conn.status == 403
      refute conn.resp_body =~ "secret"
    end
  end

  defp archive!(session_id, contents) do
    path = SessionArchive.path_for(session_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :zlib.gzip(contents))
    on_exit(fn -> File.rm(path) end)
  end
end
