defmodule ArbiterWeb.SessionTranscriptController do
  @moduledoc """
  Downloads a coordinator session's phase 9 archive (`Arbiter.Worker.
  SessionArchive`) — the durable, redacted copy of the session's own Claude
  Code JSONL. bd-cvfjms: what the issue detail page's "Transcript" link
  points at, so a refine session's conversation stays citable after the
  session itself is gone and the dock has nothing left to replay.

  Not a LiveView page — `ArbiterWeb.Router`'s `/sessions` scope deliberately
  has no `/sessions/:id` (phase 3 of the session dock moved every per-session
  control into the dock window). This is a plain file download, not a page,
  so it sits outside that rule the same way any other attachment route would.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Worker.SessionArchive

  def download(conn, %{"id" => id}) do
    case SessionArchive.read(id) do
      {:ok, jsonl} ->
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{id}.jsonl"))
        |> send_resp(200, jsonl)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("transcript not found")
    end
  end
end
