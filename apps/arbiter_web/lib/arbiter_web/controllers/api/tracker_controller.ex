defmodule ArbiterWeb.Api.TrackerController do
  @moduledoc """
  REST endpoints for querying a workspace's external tracker directly.

  Routes:

    * `GET /api/workspaces/:workspace_id/tracker/issues` — list the open
      items assigned to the workspace's authenticated user. Adapters that
      don't have a backlog notion (currently: `:none`, plus Jira/Shortcut
      until their search is wired) reply with `supported: false` and an
      empty data list, so callers (`arb list --tracker`) can degrade
      cleanly without treating it as an error.

  Response shape on success:

      {
        "data": [
          {
            "ref": "42",
            "title": "Wire the thing",
            "url": "https://github.com/o/r/issues/42",
            "status": "open",
            "assignees": ["alice"]
          },
          ...
        ],
        "supported": true
      }
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers

  action_fallback ArbiterWeb.Api.FallbackController

  def issues(conn, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <- get_workspace(workspace_id) do
      case Trackers.list_open(workspace) do
        {:ok, summaries} ->
          json(conn, %{data: Enum.map(summaries, &serialize/1), supported: true})

        {:error, :not_supported} ->
          json(conn, %{data: [], supported: false})

        {:error, %Arbiter.Trackers.GitHub.Error{} = err} ->
          tracker_error_response(conn, err)

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- serialization -----------------------------------------------------

  defp serialize(%{
         ref: ref,
         title: title,
         url: url,
         status: status,
         assignees: assignees
       }) do
    %{
      ref: ref,
      title: title,
      url: url,
      status: Atom.to_string(status),
      assignees: assignees
    }
  end

  # ---- helpers -----------------------------------------------------------

  defp get_workspace(id) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> {:ok, ws}
      {:error, _} = err -> err
    end
  end

  defp tracker_error_response(conn, %Arbiter.Trackers.GitHub.Error{} = err) do
    http_status =
      case err.kind do
        :config_missing -> :bad_request
        :unauthenticated -> :unauthorized
        :forbidden -> :forbidden
        :not_found -> :not_found
        :validation_failed -> :unprocessable_entity
        _ -> :bad_gateway
      end

    conn
    |> put_status(http_status)
    |> json(%{
      error: %{
        type: "tracker_error",
        message: err.message,
        details: %{kind: Atom.to_string(err.kind), status: err.status}
      }
    })
  end
end
