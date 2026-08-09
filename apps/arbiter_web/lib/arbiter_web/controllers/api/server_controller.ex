defmodule ArbiterWeb.Api.ServerController do
  @moduledoc """
  Server health and status endpoints.

  Routes:
    * `GET /api/server/migrations` — check for pending database migrations
  """

  use ArbiterWeb, :controller

  def migrations(conn, _params) do
    pending_count = Arbiter.Migrations.count_pending()

    json(conn, %{
      pending_count: pending_count
    })
  end
end
