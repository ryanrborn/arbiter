defmodule ArbiterWeb.SessionTranscriptController do
  @moduledoc """
  The whole of a finished session's artefacts, for the operator who wants
  more than the dock shows (bd-3tf4oo).

  The dock replays a **bounded tail** of the raw transcript
  (`Arbiter.Sessions.TranscriptReplay`) — a 100 MB file is not something to
  push into xterm. This is where the rest of it lives: `:raw` serves the
  captured PTY stream verbatim, and `:jsonl` serves the gzipped session JSONL
  `Arbiter.Worker.SessionArchive` wrote on session end, which is what the
  dock's "transcript unavailable" state links to when the raw stream is gone
  but the archive is not.

  ## Loopback only

  Both files are the session's screen and its agent transcript — redacted on
  write, but still the most sensitive bytes the dashboard can hand out. They
  are served under the same rule the terminal socket applies (§10.4,
  `ArbiterWeb.SessionSocket`): a peer on this box, or nothing. There is no
  token path here on purpose; off-box access to a session is Remote Control's
  problem (§8), and a download URL is exactly the sort of thing that gets
  pasted somewhere it should not be.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Worker.SessionArchive

  plug :require_loopback

  @doc "The raw PTY capture, verbatim — ANSI and all."
  # The served path is never built from the URL. `session_id/1` accepts only a
  # well-formed UUID *and* only one that is a real `Arbiter.Sessions.Session`
  # row, and the path is then derived from the row's own id — so `..` never
  # reaches `Path.join/2`, and `ArbiterWeb.SessionTranscriptControllerTest`
  # asserts that a traversal attempt 404s. Annotated on the two functions that
  # earn it rather than added to `.sobelow-conf`'s `ignore` list, so a new
  # `send_file/3` anywhere else in the app still fails the scan.
  # sobelow_skip ["Traversal.SendFile"]
  def raw(conn, %{"id" => id}) do
    with {:ok, session_id} <- session_id(id),
         path = Transcript.path_for(session_id),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{session_id}.raw"))
      |> send_file(200, path)
    else
      _ -> not_found(conn, "no transcript for this session")
    end
  end

  @doc "The gzipped session JSONL, as archived on session end."
  # See `raw/2` above: the path comes from the looked-up row, not the URL.
  # sobelow_skip ["Traversal.SendFile"]
  def jsonl(conn, %{"id" => id}) do
    with {:ok, session_id} <- session_id(id),
         path = SessionArchive.path_for(session_id),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{session_id}.jsonl.gz"))
      |> send_file(200, path)
    else
      _ -> not_found(conn, "no archived session JSONL for this session")
    end
  end

  # The id of a session that exists, or nothing. Both halves matter: the UUID
  # cast keeps anything path-shaped away from the lookup, and the lookup is
  # what the file path is then built from.
  defp session_id(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, session} <- Sessions.get(uuid) do
      {:ok, session.id}
    else
      _ -> :error
    end
  end

  defp require_loopback(conn, _opts) do
    if ArbiterWeb.Loopback.loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "session transcripts are served to a loopback peer only")
      |> halt()
    end
  end

  defp not_found(conn, detail) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, detail)
  end
end
