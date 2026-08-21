defmodule ArbiterWeb.WorkspaceDetail.SecretsComponent do
  @moduledoc """
  The workspace's encrypted secret registry.

  Only *names* are ever rendered: the modal posts a value, the server encrypts
  it, and only the key names come back. Other sections build their
  `credentials_ref` selects from the same names, which is why a write here
  notifies the parent rather than staying local.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

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
    <section id={@id} class="card bg-base-200 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="font-semibold flex items-center gap-2">
            <.icon name="hero-key" class="size-5 text-base-content/60" /> Secrets
            <span class="text-base-content/40 font-normal">({length(@secret_keys)})</span>
          </h2>
          <.button phx-click="open_secret_modal" phx-target={@myself} class="btn btn-sm">
            <.icon name="hero-plus" class="size-4" /> Set secret
          </.button>
        </div>
        <p class="text-xs text-base-content/50 -mt-1">
          Encrypted at rest. Only key names are shown — values are never displayed. Reference one
          from config with <code>credentials_ref: "secret:&lt;key&gt;"</code>.
        </p>

        <ul :if={@secret_keys != []} id="secret-keys" class="flex flex-col gap-1.5">
          <li
            :for={key <- @secret_keys}
            class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
          >
            <.icon name="hero-lock-closed" class="size-4 text-base-content/40 shrink-0" />
            <code class="text-sm flex-1">{key}</code>
            <span class="text-xs text-base-content/40">••••••••</span>
            <button
              type="button"
              phx-click="rm_secret"
              phx-target={@myself}
              phx-value-key={key}
              class="btn btn-ghost btn-xs text-error shrink-0"
              aria-label="Remove secret"
              data-confirm={"Remove secret #{key}?"}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>

        <p :if={@secret_keys == []} class="text-sm text-base-content/50 italic">
          No secrets set.
        </p>

        <%!-- Set-secret modal. Rendered inside the section (rather than at the
             page root as it was pre-split) so this component keeps the single
             root element a stateful LiveComponent needs; it is
             position-fixed, so where it sits in the tree doesn't matter. --%>
        <div :if={@secret_modal} class="modal modal-open" id="secret-modal">
          <div class="modal-box">
            <h3 class="font-semibold text-lg mb-3">Set secret</h3>
            <.form
              for={%{}}
              as={:secret}
              phx-submit="set_secret"
              phx-target={@myself}
              class="space-y-2"
            >
              <.input name="secret[key]" label="Key" value="" placeholder="tracker_token" required />
              <.input
                type="password"
                name="secret[value]"
                label="Value (write-only — never shown again)"
                value=""
                autocomplete="off"
                required
              />
              <p :if={@secret_error} class="text-sm text-error">{@secret_error}</p>
              <div class="modal-action">
                <.button
                  type="button"
                  phx-click="close_secret_modal"
                  phx-target={@myself}
                  class="btn btn-sm btn-ghost"
                >
                  Cancel
                </.button>
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Store
                </.button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_secret_modal" phx-target={@myself}></div>
        </div>
      </div>
    </section>
    """
  end
end
