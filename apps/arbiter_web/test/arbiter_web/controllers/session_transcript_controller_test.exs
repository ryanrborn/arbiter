defmodule ArbiterWeb.SessionTranscriptControllerTest do
  @moduledoc """
  bd-cvfjms: the issue detail page's "Transcript" link downloads a session's
  phase 9 archive (`Arbiter.Worker.SessionArchive`).
  """
  use ArbiterWeb.ConnCase

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "session-transcript-ctrl-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{root: root}
  end

  defp seed_archive!(root, id, body) do
    File.mkdir_p!(root)
    File.write!(Path.join(root, id <> ".jsonl.gz"), :zlib.gzip(body))
  end

  test "GET /sessions/:id/transcript streams the decompressed archive as a download", %{
    conn: conn,
    root: root
  } do
    id = Ash.UUID.generate()
    seed_archive!(root, id, ~s({"type":"assistant","text":"hello"}\n))

    conn = get(conn, ~p"/sessions/#{id}/transcript")

    assert response(conn, 200) == ~s({"type":"assistant","text":"hello"}\n)

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="#{id}.jsonl")
           ]
  end

  test "GET /sessions/:id/transcript 404s when the session was never archived", %{conn: conn} do
    conn = get(conn, ~p"/sessions/#{Ash.UUID.generate()}/transcript")
    assert response(conn, 404)
  end

  test "GET /sessions/:id/transcript 404s on a path-traversal id instead of reading the filesystem",
       %{conn: conn} do
    conn = get(conn, "/sessions/..%2F..%2F..%2Fetc%2Fpasswd/transcript")
    assert response(conn, 404)
  end

  test "GET /sessions/:id/transcript 404s on a 16-byte path-traversal id (Ecto.UUID's raw-binary cast clause)",
       %{conn: conn} do
    # "../../../../../x" is exactly 16 bytes, which Ecto.UUID.cast/1 accepts
    # via its raw-binary clause and re-encodes as a harmless-looking hex UUID.
    # The controller must resolve the *cast* id, not the original traversal
    # string, or this still reaches the filesystem outside the archive root.
    traversal = "../../../../../x"
    assert byte_size(traversal) == 16

    conn = get(conn, "/sessions/" <> URI.encode(traversal, &(&1 != ?/)) <> "/transcript")
    assert response(conn, 404)
  end
end
