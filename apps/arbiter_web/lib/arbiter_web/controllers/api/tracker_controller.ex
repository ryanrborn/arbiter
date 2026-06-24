defmodule ArbiterWeb.Api.TrackerController do
  @moduledoc """
  REST endpoints for querying a workspace's external tracker directly.

  Routes:

    * `GET  /api/workspaces/:workspace_id/tracker/issues` — list the open
      items assigned to the workspace's authenticated user. Adapters that
      don't have a backlog notion (currently: `:none`, plus Jira/Shortcut
      until their search is wired) reply with `supported: false` and an
      empty data list, so callers (`arb list --tracker`) can degrade
      cleanly without treating it as an error.

    * `POST /api/workspaces/:workspace_id/tracker/tickets` — create an
      upstream tracker ticket WITHOUT creating a local task. Used by
      `arb create --ticket-only` to post unclaimed work to the shared
      tracker so any fleet contributor can pick it up via `arb claim`.
      Requires a configured tracker (`tracker_type != :none`).

  `POST /tracker/tickets` response shape on success:

      {
        "ref": "42",
        "url": "https://github.com/owner/repo/issues/42",
        "tracker_type": "github"
      }
  """

  use ArbiterWeb, :controller

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers

  action_fallback ArbiterWeb.Api.FallbackController

  def issues(conn, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <- get_workspace(workspace_id) do
      case Trackers.list_open(workspace) do
        {:ok, summaries} ->
          json(conn, %{data: Enum.map(summaries, &serialize/1), supported: true})

        {:error, :not_supported} ->
          json(conn, %{data: [], supported: false})

        {:error, _} = err ->
          err
      end
    end
  end

  def create_ticket(conn, %{"workspace_id" => workspace_id} = params) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- require_tracker(workspace) do
      attrs = build_ticket_attrs(params)
      tracker_type = Trackers.workspace_type(workspace)

      case Trackers.create_for_workspace(workspace, attrs) do
        {:ok, ref} ->
          url = Trackers.link_for_workspace(workspace, ref)

          conn
          |> put_status(:created)
          |> json(%{ref: ref, url: url, tracker_type: Atom.to_string(tracker_type)})

        {:error, :not_supported} ->
          {:error,
           {:invalid_request, "tracker #{tracker_type} does not support outbound ticket creation"}}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp build_ticket_attrs(params) do
    %{}
    |> put_if_present(:title, params["title"])
    |> put_if_present(:description, params["description"])
    |> put_if_present(:assignee, params["assignee"])
    |> put_if_present(:priority, params["priority"])
    |> put_if_present(:issue_type, params["issue_type"])
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp require_tracker(workspace) do
    case Trackers.workspace_type(workspace) do
      :none ->
        {:error,
         {:invalid_request,
          "workspace has no tracker configured; use arb create (without --ticket-only) for a local task"}}

      _ ->
        :ok
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

  defp get_workspace(id) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> {:ok, ws}
      {:error, _} = err -> err
    end
  end
end
