defmodule ArbiterWeb.WorkspaceDetail.SecretsComponent do
  @moduledoc """
  The workspace's encrypted secret registry.

  Only *names* are ever rendered: the modal posts a value, the server encrypts
  it, and only the key names come back. Other sections build their
  `credentials_ref` selects from the same names, which is why a write here
  notifies the parent rather than staying local.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms

  @impl true
  def mount(socket), do: {:ok, assign(socket, secret_modal: false, secret_error: nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load_derived(socket)}
  end

  # Reloaded after this section's own write as well as on a parent update: the
  # `{:workspace_updated, _}` a write sends up is a second round trip, and
  # until it lands the list would still be missing the key just stored (or
  # still showing the one just removed).
  defp load_derived(%{assigns: %{workspace: ws}} = socket),
    do: assign(socket, :secret_keys, secret_keys(ws))

  @impl true
  def handle_event("open_secret_modal", _params, socket) do
    {:noreply, assign(socket, secret_modal: true, secret_error: nil)}
  end

  def handle_event("close_secret_modal", _params, socket) do
    {:noreply, assign(socket, secret_modal: false, secret_error: nil)}
  end

  def handle_event("set_secret", %{"secret" => %{"key" => key, "value" => value}}, socket) do
    key = String.trim(key || "")

    cond do
      key == "" ->
        {:noreply, assign(socket, :secret_error, "Secret key can't be empty.")}

      String.trim(value || "") == "" ->
        {:noreply, assign(socket, :secret_error, "Secret value can't be empty.")}

      true ->
        case set_secrets(socket.assigns.workspace, %{key => value}) do
          {:ok, ws} ->
            {:noreply,
             socket
             |> apply_workspace(ws, "Secret #{key} stored.")
             |> assign(secret_modal: false, secret_error: nil)
             |> load_derived()}

          {:error, msg} ->
            {:noreply, assign(socket, :secret_error, msg)}
        end
    end
  end

  def handle_event("rm_secret", %{"key" => key}, socket) do
    case set_secrets(socket.assigns.workspace, %{key => nil}) do
      {:ok, ws} ->
        {:noreply, socket |> apply_workspace(ws, "Secret #{key} removed.") |> load_derived()}

      {:error, msg} ->
        notify_flash(:error, msg)
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("secrets", @section)}>
      <.rows>
        <.setting_row
          name="Stored secrets"
          consequence="encrypted at rest and never shown again; reference one from config as credentials_ref: secret:<key>"
        >
          <:control>
            <Core.button type="button" phx-click="open_secret_modal" phx-target={@myself} size="sm">
              Set secret
            </Core.button>
          </:control>
          <:below>
            <ul :if={@secret_keys != []} id="secret-keys" class={list_class()}>
              <.list_row :for={key <- @secret_keys}>
                <Core.icon name="hero-lock-closed" size={13} color="var(--text-label)" />
                <span class="flex-1 truncate">{key}</span>
                <span class="text-[var(--text-label)]">••••••••</span>
                <.remove_button
                  label="Remove secret"
                  phx-click="rm_secret"
                  phx-target={@myself}
                  phx-value-key={key}
                  data-confirm={"Remove secret #{key}?"}
                />
              </.list_row>
            </ul>

            <Feedback.empty_state
              :if={@secret_keys == []}
              icon="hero-key"
              detail="no secrets stored"
            >
              Nothing here yet — tracker and agent credentials live in this list.
            </Feedback.empty_state>
          </:below>
        </.setting_row>
      </.rows>

      <%!-- Set-secret modal. Rendered inside the section (rather than at the
           page root as it was pre-split) so this component keeps the single
           root element a stateful LiveComponent needs; it is
           position-fixed, so where it sits in the tree doesn't matter. --%>
      <div :if={@secret_modal} class="modal modal-open" id="secret-modal">
        <div class="modal-box">
          <h3 class="mb-3 text-[13px] font-medium text-[var(--text-title)]">Set secret</h3>
          <.form
            for={%{}}
            as={:secret}
            phx-submit="set_secret"
            phx-target={@myself}
            class="flex flex-col gap-3"
          >
            <Forms.input
              name="secret[key]"
              label="Key"
              value=""
              size="sm"
              placeholder="tracker_token"
              required
            />
            <Forms.input
              type="password"
              name="secret[value]"
              label="Value"
              hint="write-only — never shown again"
              value=""
              size="sm"
              autocomplete="off"
              required
            />
            <p :if={@secret_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
              {@secret_error}
            </p>
            <div class="modal-action">
              <Core.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="close_secret_modal"
                phx-target={@myself}
              >
                Cancel
              </Core.button>
              <Core.button type="submit" variant="primary" size="sm">Store</Core.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_secret_modal" phx-target={@myself}></div>
      </div>
    </div>
    """
  end
end
