defmodule GtElixirWeb.Api.PolecatController do
  @moduledoc """
  REST endpoints for polecat lifecycle. The bd2 CLI calls `sling/2` to
  start work on a bead; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running polecats.

  Routes:

    * `POST /api/polecats/sling`  — :sling (body: `bead_id`, optional `rig`)
    * `GET  /api/polecats`        — :index (list active polecats)
  """

  use GtElixirWeb, :controller

  alias GtElixir.Polecat
  alias GtElixir.Polecat.Sling

  action_fallback GtElixirWeb.Api.FallbackController

  def sling(conn, params) do
    case params do
      %{"bead_id" => bead_id} when is_binary(bead_id) and bead_id != "" ->
        opts = sling_opts(params)

        case Sling.sling(bead_id, opts) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> render(:sling, result: result)

          {:error, {:bead_not_found, _}} ->
            {:error, :not_found}

          {:error, {:bead_closed, _}} ->
            {:error,
             {:invalid_request, "bead is closed; reopen it before slinging", %{bead_id: bead_id}}}

          {:error, reason} ->
            {:error, {:server_error, "sling failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "bead_id is required", %{}}}
    end
  end

  def index(conn, _params) do
    render(conn, :index, children: Polecat.list_children())
  end

  defp sling_opts(params) do
    [rig: params["rig"]]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end
end
