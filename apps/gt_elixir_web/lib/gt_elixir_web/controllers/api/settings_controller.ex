defmodule GtElixirWeb.Api.SettingsController do
  @moduledoc """
  REST endpoints for `GtElixir.Settings`.

  Routes:

    * `GET /api/settings`                  — :show
    * `PUT /api/settings/vernacular`        — :update_vernacular
  """

  use GtElixirWeb, :controller

  alias GtElixir.Settings

  action_fallback(GtElixirWeb.Api.FallbackController)

  def show(conn, _params) do
    case Settings.get() do
      {:ok, settings} -> render(conn, :show, settings: settings)
      {:error, _} = err -> err
    end
  end

  def update_vernacular(conn, %{"vernacular" => vernacular}) when is_map(vernacular) do
    with {:ok, settings} <- Settings.get(),
         {:ok, updated} <- Settings.update_vernacular(settings, vernacular) do
      render(conn, :show, settings: updated)
    end
  end
end
