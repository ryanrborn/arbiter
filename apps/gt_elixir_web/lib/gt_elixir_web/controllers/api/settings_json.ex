defmodule GtElixirWeb.Api.SettingsJSON do
  @doc "Render global settings."
  def show(%{settings: settings}) do
    %{data: data(settings)}
  end

  defp data(settings) do
    %{
      id: settings.id,
      vernacular: settings.vernacular,
      inserted_at: settings.inserted_at,
      updated_at: settings.updated_at
    }
  end
end
