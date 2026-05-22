defmodule ArbiterWeb.Api.ConvoyController do
  @moduledoc """
  REST endpoints for `Arbiter.Beads.Convoy`.

  Routes:

    * `POST  /api/convoys`            — :create
    * `GET   /api/convoys/:id`        — :show (loads memberships + aggregates)
    * `POST  /api/convoys/:id/close`  — :close
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.Convoy

  action_fallback ArbiterWeb.Api.FallbackController

  @load [:memberships, :total_issues, :closed_issues]

  def create(conn, params) do
    attrs = coerce_lifecycle(params)

    with {:ok, convoy} <-
           Ash.create(Convoy, Map.take(attrs, ["title", "lifecycle", "workspace_id"])),
         {:ok, loaded} <- Ash.load(convoy, @load) do
      conn
      |> put_status(:created)
      |> render(:show, convoy: loaded)
    end
  end

  def show(conn, %{"id" => id}) do
    case Ash.get(Convoy, id, load: @load) do
      {:ok, convoy} -> render(conn, :show, convoy: convoy)
      {:error, _} = err -> err
    end
  end

  def close(conn, %{"id" => id} = params) do
    reason = params["reason"]
    args = if reason, do: %{reason: reason}, else: %{}

    with {:ok, convoy} <- Ash.get(Convoy, id),
         {:ok, closed} <- Ash.update(convoy, args, action: :close),
         {:ok, loaded} <- Ash.load(closed, @load) do
      render(conn, :show, convoy: loaded)
    end
  end

  defp coerce_lifecycle(%{"lifecycle" => l} = params) when is_binary(l) do
    try do
      Map.put(params, "lifecycle", String.to_existing_atom(l))
    rescue
      ArgumentError -> params
    end
  end

  defp coerce_lifecycle(params), do: params
end
