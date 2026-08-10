defmodule ArbiterWeb.Api.ServerController do
  @moduledoc """
  Server health and status endpoints.

  Routes:
    * `GET /api/server/migrations` — check for pending database migrations
  """

  use ArbiterWeb, :controller

  def migrations(conn, _params) do
    case Arbiter.Migrations.count_pending() do
      {:ok, 0} ->
        json(conn, %{
          status: "ok",
          pending_count: 0
        })

      {:ok, count} ->
        json(conn, %{
          status: "warning",
          pending_count: count
        })

      {:error, reason} ->
        json(conn, %{
          status: "unknown",
          pending_count: nil,
          error: Atom.to_string(reason)
        })
    end
  end
end
