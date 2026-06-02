defmodule ArbiterWeb.Api.SettingsController do
  @moduledoc """
  REST endpoints for `Arbiter.Settings`.

  Routes:

    * `GET /api/settings`                  — :show
    * `PUT /api/settings/vernacular`        — :update_vernacular
    * `PUT /api/settings/branding`          — :update_branding
  """

  use ArbiterWeb, :controller

  alias Arbiter.Settings

  action_fallback(ArbiterWeb.Api.FallbackController)

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

  def update_branding(conn, %{"branding" => branding}) when is_map(branding) do
    with {:ok, settings} <- Settings.get(),
         {:ok, updated} <- Settings.update_branding(settings, branding) do
      render(conn, :show, settings: updated)
    end
  end
end
