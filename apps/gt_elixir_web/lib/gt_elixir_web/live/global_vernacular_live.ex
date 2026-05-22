defmodule GtElixirWeb.GlobalVernacularLive do
  @moduledoc """
  LiveView at `/settings/vernacular` — edit the installation-wide vernacular.

  Reads from and writes to `GtElixir.Settings` (the singleton global
  settings row). Changes apply across all workspaces immediately.
  """

  use GtElixirWeb, :live_view

  alias GtElixir.{Settings, Vernacular}

  @impl true
  def mount(_params, _session, socket) do
    case Settings.get() do
      {:ok, settings} ->
        {:ok,
         socket
         |> assign(:settings, settings)
         |> assign(:json_input, Jason.encode!(settings.vernacular, pretty: true))
         |> assign(:json_error, nil)
         |> assign(:preview, settings.vernacular)
         |> assign(:saved_at, nil)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Could not load global settings.")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("update_json", %{"vernacular" => %{"json" => json}}, socket) do
    case parse_vernacular(json) do
      {:ok, parsed} ->
        {:noreply,
         socket
         |> assign(:json_input, json)
         |> assign(:json_error, nil)
         |> assign(:preview, parsed)}

      {:error, msg} ->
        {:noreply,
         socket
         |> assign(:json_input, json)
         |> assign(:json_error, msg)}
    end
  end

  @impl true
  def handle_event("save", _params, socket) do
    json = socket.assigns.json_input

    with {:ok, parsed} <- parse_vernacular(json),
         {:ok, updated} <- Settings.update_vernacular(socket.assigns.settings, parsed) do
      Vernacular.put_active(%{"vernacular" => updated.vernacular})

      {:noreply,
       socket
       |> assign(:settings, updated)
       |> assign(:saved_at, DateTime.utc_now())
       |> assign(:json_error, nil)
       |> put_flash(:info, "Vernacular saved.")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, :json_error, msg)}

      {:error, _} ->
        {:noreply, assign(socket, :json_error, "save failed (see logs)")}
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    defaults_json =
      Vernacular.defaults()
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Jason.encode!(pretty: true)

    {:noreply,
     socket
     |> assign(:json_input, defaults_json)
     |> assign(:json_error, nil)
     |> assign(:preview, Map.new(Vernacular.defaults(), fn {k, v} -> {Atom.to_string(k), v} end))}
  end

  defp parse_vernacular(""), do: {:ok, %{}}

  defp parse_vernacular(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, "vernacular JSON must be an object"}
      {:error, %Jason.DecodeError{} = e} -> {:error, "invalid JSON: #{Exception.message(e)}"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
    <div class="p-6 max-w-6xl mx-auto">
      <h1 class="text-2xl font-bold mb-1">Vernacular settings</h1>
      <p class="text-sm text-base-content/70 mb-6">
        Global — applies across all workspaces.
      </p>

      <div class="grid grid-cols-2 gap-6">
        <div>
          <h2 class="text-lg font-semibold mb-2">JSON editor</h2>
          <form phx-change="update_json" phx-submit="save">
            <textarea
              name="vernacular[json]"
              rows="20"
              class="textarea textarea-bordered w-full font-mono text-sm"
              phx-debounce="200"
            >{@json_input}</textarea>

            <%= if @json_error do %>
              <div class="alert alert-error mt-2 text-sm">{@json_error}</div>
            <% end %>

            <div class="flex gap-2 mt-3">
              <button type="submit" class="btn btn-primary" disabled={not is_nil(@json_error)}>
                Save
              </button>
              <button type="button" phx-click="reset" class="btn btn-ghost">
                Reset to defaults
              </button>
              <%= if @saved_at do %>
                <span class="text-xs text-success self-center">
                  saved {Calendar.strftime(@saved_at, "%H:%M:%S UTC")}
                </span>
              <% end %>
            </div>
          </form>
        </div>

        <div>
          <h2 class="text-lg font-semibold mb-2">Preview</h2>
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Internal</th>
                <th>Your label</th>
              </tr>
            </thead>
            <tbody>
              <%= for key <- Vernacular.keys() do %>
                <tr>
                  <td><code class="text-xs">{Atom.to_string(key)}</code></td>
                  <td>
                    {Map.get(@preview, Atom.to_string(key), Vernacular.defaults()[key])}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%= if (Map.get(@preview, "aliases") || %{}) != %{} do %>
            <h3 class="text-sm font-semibold mt-4">Aliases</h3>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Alias</th>
                  <th>Canonical</th>
                </tr>
              </thead>
              <tbody>
                <%= for {alias_, canonical} <- Map.get(@preview, "aliases", %{}) do %>
                  <tr>
                    <td><code class="text-xs">{alias_}</code></td>
                    <td><code class="text-xs">{canonical}</code></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>
    </Layouts.app>
    """
  end
end
