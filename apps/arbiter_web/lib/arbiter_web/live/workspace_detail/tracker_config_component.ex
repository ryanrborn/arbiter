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

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

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
  # `{field, label, consequence}` — the consequence is what the field *does*,
  # not what it is called, because the label alone never tells an operator
  # whether leaving it blank is safe.
  defp tracker_adapter_fields("jira") do
    [
      {"host", "Host", "the Jira site issues are read from and written back to"},
      {"project_key", "Project key", "new issues are filed under this project"},
      {"email", "Email", "the account the API token belongs to; blank uses token-only auth"}
    ]
  end

  defp tracker_adapter_fields("shortcut") do
    [
      {"workflow_id", "Workflow ID",
       "new stories land in this workflow; blank uses the org's default"}
    ]
  end

  defp tracker_adapter_fields("linear") do
    [
      {"team_id", "Team ID", "issues are created on this team; blank uses the token's default"},
      {"org_url_key", "Org URL key", "used to build the issue links shown on the board"},
      {"base_url", "Base URL", "point at a self-hosted API; blank uses linear.app"}
    ]
  end

  defp tracker_adapter_fields("github") do
    [
      {"owner", "Owner", "the account or org whose issues this workspace syncs"},
      {"repo", "Repo", "the repository issues are read from and filed in"},
      {"base_url", "Base URL", "point at a GitHub Enterprise API; blank uses github.com"}
    ]
  end

  defp tracker_adapter_fields("gitlab") do
    [
      {"host", "Host", "the GitLab instance issues are read from and written back to"},
      {"project_id", "Project ID or path", "the project issues are read from and filed in"}
    ]
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
    <div id={@id} class="flex flex-col gap-4">
      <.form for={%{}} as={:tracker_config} phx-submit="save_tracker_config" phx-target={@myself}>
        <input type="hidden" name="tracker_config[type]" value={@type_preview} />
        <.rows>
          <.setting_row
            :for={{field, label, consequence} <- tracker_adapter_fields(@type_preview)}
            name={label}
            consequence={consequence}
          >
            <:control>
              <Forms.input
                name={"tracker_config[#{field}]"}
                value={tracker_cfg(@workspace, field)}
                size="sm"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            name="Credentials"
            consequence="tracker.config.credentials_ref — which stored secret the adapter authenticates with; add one under Secrets first"
          >
            <:control>
              <Forms.select
                name="tracker_config[credentials_ref]"
                options={
                  credentials_ref_options(@secret_keys, tracker_cfg(@workspace, "credentials_ref"))
                }
                value={tracker_cfg(@workspace, "credentials_ref")}
                size="sm"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>
        </.rows>

        <div class="mt-3 flex items-center gap-3">
          <Core.button type="submit" variant="primary" size="sm">Save tracker config</Core.button>
          <p :if={@tracker_config_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
            {@tracker_config_error}
          </p>
        </div>
      </.form>

      <p class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]">
        Picking another tracker type under Policy swaps these fields; a saved type's config is kept
        while another is selected, so switching back doesn't lose it. Blank unsets a field.
      </p>
    </div>
    """
  end
end
