defmodule ArbiterWeb.WorkspaceDetail.TrackerConfigComponent do
  @moduledoc """
  `tracker.config.*` — the adapter-specific fields for whichever tracker type
  is currently selected.

  The type comes in as `@type_preview` rather than being read from config: the
  policy form live-updates it on change, so the operator sees the right fields
  before saving the type. Only the selected adapter's fields are written, which
  is what lets a saved type's config survive while another type is selected.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  @impl true
  def mount(socket), do: {:ok, assign(socket, :tracker_config_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :secret_keys, secret_keys(socket.assigns.workspace))}
  end

  @impl true
  def handle_event("save_tracker_config", %{"tracker_config" => params}, socket) do
    type = params["type"] || cfg(socket.assigns.workspace, ["tracker", "type"], "none")
    {patch, unset} = tracker_config_patch(type, params)

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws, "Tracker config saved.")
         |> assign(:tracker_config_error, nil)}

      {:error, msg} ->
        {:noreply, assign(socket, :tracker_config_error, msg)}
    end
  end

  # The plain string/select fields each adapter's `Config.resolve/0` actually
  # reads out of `tracker.config` (see `apps/arbiter/lib/arbiter/trackers/
  # {jira,shortcut,linear,github,gitlab}/config.ex`). `credentials_ref` is
  # common to every adapter and rendered separately as a secret select, so it
  # isn't listed here.
  defp tracker_adapter_fields("jira") do
    [{"host", "Host"}, {"project_key", "Project key"}, {"email", "Email (optional)"}]
  end

  defp tracker_adapter_fields("shortcut") do
    [{"workflow_id", "Workflow ID (optional)"}]
  end

  defp tracker_adapter_fields("linear") do
    [
      {"team_id", "Team ID (optional)"},
      {"org_url_key", "Org URL key (optional)"},
      {"base_url", "Base URL (optional)"}
    ]
  end

  defp tracker_adapter_fields("github") do
    [{"owner", "Owner"}, {"repo", "Repo"}, {"base_url", "Base URL (optional, GHE)"}]
  end

  defp tracker_adapter_fields("gitlab") do
    [{"host", "Host"}, {"project_id", "Project ID or path"}]
  end

  defp tracker_adapter_fields(_type), do: []

  defp tracker_cfg(ws, field) do
    case cfg(ws, ["tracker", "config", field]) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  # Builds the `tracker.config` patch/unset for the currently-selected
  # adapter's fields only — the config underneath every *other* tracker type
  # is untouched, so `patch_config`'s deep-merge preserves it and switching
  # `tracker.type` back and forth doesn't discard it.
  defp tracker_config_patch(type, params) do
    fields = tracker_adapter_fields(type) |> Enum.map(&elem(&1, 0))
    fields = if type == "none", do: fields, else: fields ++ ["credentials_ref"]

    {patch, unset} =
      Enum.reduce(fields, {%{}, []}, fn field, {patch, unset} ->
        case blank_to_nil(params[field]) do
          nil -> {patch, unset ++ ["tracker.config.#{field}"]}
          v -> {Map.put(patch, field, v), unset}
        end
      end)

    {%{"tracker" => %{"config" => patch}}, unset}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="border-t border-base-300 pt-3">
      <h3 class="font-semibold text-sm flex items-center gap-2">
        <.icon name="hero-ticket" class="size-4 text-base-content/60" />
        {String.capitalize(@type_preview)} tracker config
      </h3>
      <p class="text-xs text-base-content/50 mt-1">
        <code>tracker.config.*</code>
        — fields the {@type_preview} adapter reads. Switching the tracker
        type above (before saving it) changes which fields show here; a saved type's
        config is kept even while another type is selected, so switching back doesn't
        lose it. Blank unsets the field.
      </p>

      <.form
        for={%{}}
        as={:tracker_config}
        phx-submit="save_tracker_config"
        phx-target={@myself}
        class="grid sm:grid-cols-2 gap-x-4 mt-2"
      >
        <input type="hidden" name="tracker_config[type]" value={@type_preview} />
        <.input
          :for={{field, label} <- tracker_adapter_fields(@type_preview)}
          type="text"
          name={"tracker_config[#{field}]"}
          label={"#{label} (tracker.config.#{field})"}
          value={tracker_cfg(@workspace, field)}
        />
        <.input
          type="select"
          name="tracker_config[credentials_ref]"
          label="Credentials (tracker.config.credentials_ref)"
          options={credentials_ref_options(@secret_keys, tracker_cfg(@workspace, "credentials_ref"))}
          value={tracker_cfg(@workspace, "credentials_ref")}
        />
        <div class="sm:col-span-2 flex items-center gap-3 mt-2">
          <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
            Save tracker config
          </.button>
          <p :if={@tracker_config_error} class="text-sm text-error">
            {@tracker_config_error}
          </p>
        </div>
      </.form>
    </div>
    """
  end
end
