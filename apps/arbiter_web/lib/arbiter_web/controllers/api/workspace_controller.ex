defmodule ArbiterWeb.Api.WorkspaceController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Workspace`.

  Routes:

    * `POST  /api/workspaces`            — :create
    * `GET   /api/workspaces`            — :index
    * `GET   /api/workspaces/:id`        — :show
    * `PATCH /api/workspaces/:id`        — :update (also `PUT`)
    * `PATCH /api/workspaces/:id/config` — :patch_config (deep-merge / unset)
  """

  use ArbiterWeb, :controller

  alias Arbiter.Tasks.Workspace

  action_fallback ArbiterWeb.Api.FallbackController

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
    # `secrets` is a write-only action argument (merge-patched then encrypted
    # via ash_cloak); it is never read back in any response. See WorkspaceJSON.
    attrs = Map.take(params, ["name", "description", "prefix", "config", "secrets"])

    case Ash.create(Workspace, attrs) do
      {:ok, ws} ->
        conn
        |> put_status(:created)
        |> render(:show, workspace: ws)

      {:error, _} = err ->
        err
    end
  end

  def update(conn, %{"id" => id} = params) do
    # `secrets`, when present, is merge-patched into the existing encrypted
    # secrets (a key with a null value removes it); omitting it leaves them
    # untouched. Write-only — never serialised back. See WorkspaceJSON.
    attrs = Map.take(params, ["name", "description", "prefix", "config", "secrets"])

    with {:ok, ws} <- Ash.get(Workspace, id),
         {:ok, updated} <- Ash.update(ws, attrs) do
      render(conn, :show, workspace: updated)
    end
  end

  @doc """
  Field-level config update. Body shape:

      {
        "patch": {"merge": {"auto_merge": true}},
        "unset_paths": ["tracker.config.host"]
      }

  Both keys are optional. The existing `config` is read, `unset_paths` are
  removed, then `patch` is deep-merged in (siblings preserved). The result
  is validated; on failure the existing config is untouched.
  """
  def patch_config(conn, %{"id" => id} = params) do
    patch = Map.get(params, "patch") || %{}
    unset_paths = Map.get(params, "unset_paths") || []

    args = %{patch: patch, unset_paths: unset_paths}

    with {:ok, ws} <- Ash.get(Workspace, id),
         {:ok, updated} <- Ash.update(ws, args, action: :patch_config) do
      render(conn, :show, workspace: updated)
    end
  end
end
