defmodule ArbiterWeb.Api.ConvoyController do
  @moduledoc """
  REST endpoints for `Arbiter.Beads.Convoy`.

  Routes:

    * `POST   /api/convoys`                      — :create
    * `GET    /api/convoys/:id`                  — :show (loads memberships + aggregates)
    * `POST   /api/convoys/:id/close`            — :close
    * `POST   /api/convoys/:id/members`          — :add_member    (body: {issue_id})
    * `DELETE /api/convoys/:id/members/:issue_id`— :remove_member

  Membership add/remove are idempotent on the `(convoy_id, issue_id)` unique
  index: adding an existing member or removing an absent one is a no-op that
  still returns the convoy's current state.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.{Convoy, ConvoyMembership}

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

  def add_member(conn, %{"id" => id, "issue_id" => issue_id}) do
    with {:ok, _convoy} <- Ash.get(Convoy, id),
         {:ok, _membership} <-
           Ash.create(ConvoyMembership, %{convoy_id: id, issue_id: issue_id}, action: :add),
         {:ok, loaded} <- Ash.get(Convoy, id, load: @load) do
      render(conn, :show, convoy: loaded)
    end
  end

  def add_member(_conn, _params), do: {:error, {:invalid_request, "issue_id is required"}}

  def remove_member(conn, %{"id" => id, "issue_id" => issue_id}) do
    with {:ok, _convoy} <- Ash.get(Convoy, id),
         :ok <- detach_member(id, issue_id),
         {:ok, loaded} <- Ash.get(Convoy, id, load: @load) do
      render(conn, :show, convoy: loaded)
    end
  end

  # Idempotent: a missing membership is treated as already-removed.
  defp detach_member(convoy_id, issue_id) do
    case Ash.get(ConvoyMembership, %{convoy_id: convoy_id, issue_id: issue_id}) do
      {:ok, membership} ->
        case Ash.destroy(membership) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, _} ->
        :ok
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
