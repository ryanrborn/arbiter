defmodule GtElixirWeb.Api.WorkspaceController do
  @moduledoc """
  REST endpoints for `GtElixir.Beads.Workspace`.

  Routes:

    * `POST /api/workspaces`     — :create
    * `GET  /api/workspaces`     — :index
    * `GET  /api/workspaces/:id` — :show
  """

  use GtElixirWeb, :controller

  alias GtElixir.Beads.Workspace

  action_fallback GtElixirWeb.Api.FallbackController

  def index(conn, _params) do
    case Ash.read(Workspace) do
      {:ok, workspaces} -> render(conn, :index, workspaces: workspaces)
      {:error, _} = err -> err
    end
  end

  def show(conn, %{"id" => id}) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> render(conn, :show, workspace: ws)
      {:error, _} = err -> err
    end
  end

  def create(conn, params) do
    attrs = Map.take(params, ["name", "description", "prefix", "config"])

    case Ash.create(Workspace, attrs) do
      {:ok, ws} ->
        conn
        |> put_status(:created)
        |> render(:show, workspace: ws)

      {:error, _} = err ->
        err
    end
  end
end
