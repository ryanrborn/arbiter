defmodule GtElixirWeb.Api.PolecatController do
  @moduledoc """
  REST endpoints for polecat lifecycle. The bd2 CLI calls `sling/2` to
  start work on a bead; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running polecats.

  Routes:

    * `POST /api/polecats/sling`           — :sling (body: `bead_id`, optional `rig`, `with_claude`)
    * `GET  /api/polecats`                 — :index (list active polecats)
    * `GET  /api/polecats/:bead_id`        — :show (full snapshot inc. recent output)
    * `POST /api/polecats/:bead_id/stop`   — :stop (terminate polecat cleanly)
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

  def show(conn, %{"bead_id" => bead_id}) when is_binary(bead_id) and bead_id != "" do
    case Polecat.whereis(bead_id) do
      nil ->
        {:error, :not_found}

      pid ->
        case Polecat.state(pid) do
          %{} = snap ->
            render(conn, :show, snapshot: Map.put(snap, :pid, pid))

          _ ->
            {:error, :not_found}
        end
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

  def stop(conn, %{"bead_id" => bead_id}) when is_binary(bead_id) and bead_id != "" do
    case Polecat.stop(bead_id, :normal) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{bead_id: bead_id, stopped: true})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def stop(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

  defp sling_opts(params) do
    [rig: params["rig"], start_claude: truthy(params["with_claude"])]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp truthy(nil), do: nil
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(false), do: false
  defp truthy("false"), do: false
  defp truthy(_), do: nil
end
