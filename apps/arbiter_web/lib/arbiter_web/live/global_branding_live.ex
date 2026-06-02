defmodule ArbiterWeb.GlobalBrandingLive do
  @moduledoc """
  LiveView at `/settings/branding` — edit the installation-wide branding.

  Reads from and writes to `Arbiter.Settings` (the singleton global settings
  row). A neutral default ships in the box; dropping a `branding` object here
  loads a personal theme (mark, wordmark, favicon, accent) without forking.
  Changes apply on the next page load.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.{Branding, Settings}

  @impl true
  def mount(_params, _session, socket) do
    case Settings.get() do
      {:ok, settings} ->
        {:ok,
         socket
         |> assign(:settings, settings)
         |> assign(:json_input, Jason.encode!(settings.branding, pretty: true))
         |> assign(:json_error, nil)
         |> assign(:preview, settings.branding)
         |> assign(:saved_at, nil)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Could not load global settings.")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("update_json", %{"branding" => %{"json" => json}}, socket) do
    case parse_branding(json) do
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

    with {:ok, parsed} <- parse_branding(json),
         {:ok, updated} <- Settings.update_branding(socket.assigns.settings, parsed) do
      Branding.put_active(%{"branding" => updated.branding})

      {:noreply,
       socket
       |> assign(:settings, updated)
       |> assign(:saved_at, DateTime.utc_now())
       |> assign(:json_error, nil)
       |> put_flash(:info, "Branding saved — reload to see it everywhere.")}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, :json_error, msg)}

      {:error, _} ->
        {:noreply, assign(socket, :json_error, "save failed (see logs)")}
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:json_input, "{}")
     |> assign(:json_error, nil)
     |> assign(:preview, %{})}
  end

  defp parse_branding(""), do: {:ok, %{}}

  defp parse_branding(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, "branding JSON must be an object"}
      {:error, %Jason.DecodeError{} = e} -> {:error, "invalid JSON: #{Exception.message(e)}"}
    end
  end

  # Resolved value for a key: the previewed override, else the neutral default.
  defp preview_value(preview, key) do
    case Map.get(preview, Atom.to_string(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> Branding.defaults()[key]
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:name, preview_value(assigns.preview, :name))
      |> assign(:mark, preview_value(assigns.preview, :mark))
      |> assign(:wordmark, preview_value(assigns.preview, :wordmark))
      |> assign(:favicon, preview_value(assigns.preview, :favicon))
      |> assign(:accent, preview_value(assigns.preview, :accent))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div class="flex items-center gap-3">
          <.icon name="hero-sparkles" class="size-7 text-primary" />
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Branding settings</h1>
            <p class="text-sm text-base-content/60">
              Global — the top-bar logo, favicon, name, and accent. Leave blank for the neutral default.
            </p>
          </div>
        </div>

        <%!-- ── Editor / Preview ─────────────────────────────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- JSON editor --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-6 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-code-bracket" class="size-5 text-primary" /> JSON editor
              </h2>

              <form phx-change="update_json" phx-submit="save" class="flex flex-col gap-4">
                <textarea
                  id="branding-json"
                  name="branding[json]"
                  rows="14"
                  class={[
                    "textarea textarea-bordered w-full font-mono text-sm leading-relaxed bg-base-100",
                    "focus-visible:ring-2 focus-visible:ring-primary transition-colors duration-150",
                    @json_error && "textarea-error"
                  ]}
                  phx-debounce="200"
                >{@json_input}</textarea>

                <div :if={@json_error} class="alert alert-error text-sm py-2">
                  <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                  <span>{@json_error}</span>
                </div>

                <p class="text-xs text-base-content/60 leading-relaxed">
                  Keys: <code>name</code>, <code>mark</code>, <code>wordmark</code>, <code>favicon</code>, <code>accent</code>. Image keys are static asset
                  paths (drop files in <code>priv/static/images</code>); <code>accent</code>
                  is any CSS colour.
                </p>

                <div class="flex flex-wrap items-center gap-3">
                  <.button
                    type="submit"
                    class="btn-primary active:scale-95 transition-transform duration-150"
                    disabled={not is_nil(@json_error)}
                  >
                    <.icon name="hero-check" class="size-4" /> Save
                  </.button>
                  <.button
                    type="button"
                    phx-click="reset"
                    class="btn-ghost active:scale-95 transition-transform duration-150"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Reset to defaults
                  </.button>

                  <span
                    :if={@saved_at}
                    class="ml-auto inline-flex items-center gap-1.5 text-sm font-medium text-success"
                  >
                    <.icon name="hero-check-circle" class="size-5" />
                    saved {Calendar.strftime(@saved_at, "%H:%M:%S UTC")}
                  </span>
                </div>
              </form>
            </div>
          </section>

          <%!-- Preview --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-6 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-eye" class="size-5 text-info" /> Preview
              </h2>

              <%!-- Mock top bar --%>
              <div class="rounded-box border border-base-300 bg-base-200 px-4 py-2 flex items-center gap-2">
                <img src={@wordmark} alt={@name} class="h-7 w-auto" />
                <span class="ml-auto text-xs text-base-content/50">top bar</span>
              </div>

              <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
                <table class="table table-sm">
                  <tbody>
                    <tr class="hover:bg-base-200/50">
                      <td class="font-medium">Name</td>
                      <td>{@name}</td>
                    </tr>
                    <tr class="hover:bg-base-200/50">
                      <td class="font-medium">Mark</td>
                      <td>
                        <img src={@mark} alt={@name} class="size-10 object-contain" />
                      </td>
                    </tr>
                    <tr class="hover:bg-base-200/50">
                      <td class="font-medium">Favicon</td>
                      <td><img src={@favicon} alt="favicon" class="size-5 object-contain" /></td>
                    </tr>
                    <tr class="hover:bg-base-200/50">
                      <td class="font-medium">Accent</td>
                      <td>
                        <span :if={@accent} class="inline-flex items-center gap-2">
                          <span
                            class="inline-block size-5 rounded-full border border-base-300"
                            style={"background: #{@accent};"}
                          />
                          <code class="text-xs">{@accent}</code>
                        </span>
                        <span :if={!@accent} class="text-base-content/50 text-sm">
                          theme default
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
