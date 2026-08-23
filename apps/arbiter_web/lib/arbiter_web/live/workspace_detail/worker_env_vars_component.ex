defmodule ArbiterWeb.WorkspaceDetail.WorkerEnvVarsComponent do
  @moduledoc """
  User-defined env vars injected into every worker's subprocess
  (`Arbiter.Worker.WorkerEnv`).

  Each may be flagged *secret*, which encrypts it and redacts its value from
  worker logs; secret values are masked in the list with an explicit reveal,
  and the flag can be toggled in place without re-entering the value. Which
  rows are currently revealed is view state and stays in this component.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       worker_env_modal: false,
       worker_env_error: nil,
       revealed_worker_env: MapSet.new()
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load_env(socket)}
  end

  defp load_env(%{assigns: %{workspace: ws}} = socket) do
    socket
    |> assign(:worker_env_keys, Workspace.worker_env_keys(ws))
    |> assign(:worker_env_values, Workspace.worker_env_map(ws))
  end

  @impl true
  def handle_event("open_worker_env_modal", _params, socket) do
    {:noreply, assign(socket, worker_env_modal: true, worker_env_error: nil)}
  end

  def handle_event("close_worker_env_modal", _params, socket) do
    {:noreply, assign(socket, worker_env_modal: false, worker_env_error: nil)}
  end

  def handle_event("set_worker_env", %{"worker_env" => params}, socket) do
    key = String.trim(params["key"] || "")
    value = params["value"] || ""
    secret? = params["secret"] in ["true", "on", true]

    cond do
      key == "" ->
        {:noreply, assign(socket, :worker_env_error, "Name can't be empty.")}

      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) ->
        {:noreply,
         assign(
           socket,
           :worker_env_error,
           "Name must match [A-Za-z_][A-Za-z0-9_]* (e.g. API_TOKEN)."
         )}

      String.trim(value) == "" ->
        {:noreply, assign(socket, :worker_env_error, "Value can't be empty.")}

      true ->
        patch = %{key => %{"value" => value, "secret" => secret?}}

        case set_worker_env(socket.assigns.workspace, patch) do
          {:ok, ws} ->
            {:noreply,
             socket
             |> apply_workspace(ws, "Worker env var #{key} saved.")
             |> assign(worker_env_modal: false, worker_env_error: nil)
             |> load_env()}

          {:error, msg} ->
            {:noreply, assign(socket, :worker_env_error, msg)}
        end
    end
  end

  def handle_event("rm_worker_env", %{"key" => key}, socket) do
    case set_worker_env(socket.assigns.workspace, %{key => nil}) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws, "Worker env var #{key} removed.")
         |> update(:revealed_worker_env, &MapSet.delete(&1, key))
         |> load_env()}

      {:error, msg} ->
        notify_flash(:error, msg)
        {:noreply, socket}
    end
  end

  # The key can be gone by the time the click lands (removed in another tab, or
  # by another operator), so match it explicitly rather than coercing a missing
  # key into a flag — a stale click is a no-op, not a crash.
  def handle_event("toggle_worker_env_secret", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.worker_env_keys, &(&1.name == key)) do
      nil ->
        notify_flash(:error, "Worker env var #{key} no longer exists.")
        {:noreply, socket}

      %{secret?: secret?} ->
        toggle_secret(socket, key, not secret?)
    end
  end

  def handle_event("reveal_worker_env", %{"key" => key}, socket) do
    {:noreply, update(socket, :revealed_worker_env, &MapSet.put(&1, key))}
  end

  def handle_event("hide_worker_env", %{"key" => key}, socket) do
    {:noreply, update(socket, :revealed_worker_env, &MapSet.delete(&1, key))}
  end

  defp toggle_secret(socket, key, new_flag) do
    case set_worker_env(socket.assigns.workspace, %{key => %{"secret" => new_flag}}) do
      {:ok, ws} ->
        {:noreply,
         socket
         # Re-hide the value whenever it flips to secret.
         |> update(:revealed_worker_env, &if(new_flag, do: MapSet.delete(&1, key), else: &1))
         |> apply_workspace(ws)
         |> load_env()}

      {:error, msg} ->
        notify_flash(:error, msg)
        {:noreply, socket}
    end
  end

  # Value shown for a worker env var row: a secret value stays masked until the
  # operator explicitly reveals it; plain values are shown inline.
  defp worker_env_display(%{name: name, secret?: true}, values, revealed) do
    if MapSet.member?(revealed, name), do: Map.get(values, name, ""), else: "••••••••"
  end

  defp worker_env_display(%{name: name}, values, _revealed), do: Map.get(values, name, "")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("security", @section)}>
      <.rows>
        <.setting_row
          name="Worker env vars"
          consequence="injected into every worker's subprocess environment; a secret one is encrypted at rest and redacted from worker logs"
        >
          <:control>
            <Core.button
              type="button"
              phx-click="open_worker_env_modal"
              phx-target={@myself}
              size="sm"
            >
              Set variable
            </Core.button>
          </:control>
          <:below>
            <ul :if={@worker_env_keys != []} id="worker-env-keys" class={list_class()}>
              <.list_row :for={entry <- @worker_env_keys}>
                <Core.icon
                  name={if entry.secret?, do: "hero-lock-closed", else: "hero-lock-open"}
                  size={13}
                  color="var(--text-label)"
                />
                <span class="flex-none">{entry.name}</span>
                <span class="text-[var(--text-label)]">=</span>
                <span class="flex-1 truncate text-[var(--text-secondary)]">
                  {worker_env_display(entry, @worker_env_values, @revealed_worker_env)}
                </span>
                <button
                  :if={entry.secret? and not MapSet.member?(@revealed_worker_env, entry.name)}
                  type="button"
                  phx-click="reveal_worker_env"
                  phx-target={@myself}
                  phx-value-key={entry.name}
                  class="shrink-0 cursor-pointer text-[var(--text-label)] hover:text-[var(--text-body)]"
                  aria-label="Reveal value"
                >
                  <Core.icon name="hero-eye" size={13} />
                </button>
                <button
                  :if={entry.secret? and MapSet.member?(@revealed_worker_env, entry.name)}
                  type="button"
                  phx-click="hide_worker_env"
                  phx-target={@myself}
                  phx-value-key={entry.name}
                  class="shrink-0 cursor-pointer text-[var(--text-label)] hover:text-[var(--text-body)]"
                  aria-label="Hide value"
                >
                  <Core.icon name="hero-eye-slash" size={13} />
                </button>
                <button
                  type="button"
                  phx-click="toggle_worker_env_secret"
                  phx-target={@myself}
                  phx-value-key={entry.name}
                  class={[
                    "shrink-0 cursor-pointer rounded-[var(--radius-chip)] border border-solid px-[6px] py-[1px] text-[10.5px]",
                    entry.secret? && "border-[var(--arb-attention)] text-[var(--arb-attention)]",
                    !entry.secret? && "border-[var(--border-default)] text-[var(--text-label)]"
                  ]}
                  title="Toggle secret"
                >
                  {if entry.secret?, do: "secret", else: "plain"}
                </button>
                <.remove_button
                  label="Remove worker env var"
                  phx-click="rm_worker_env"
                  phx-target={@myself}
                  phx-value-key={entry.name}
                  data-confirm={"Remove worker env var #{entry.name}?"}
                />
              </.list_row>
            </ul>

            <Feedback.empty_state
              :if={@worker_env_keys == []}
              icon="hero-variable"
              detail="no worker env vars set"
            >
              Workers run with the dispatcher's environment only.
            </Feedback.empty_state>
          </:below>
        </.setting_row>
      </.rows>

      <%!-- Set-worker-env modal — see the note on the secrets modal for why
           it renders inside the section. --%>
      <div :if={@worker_env_modal} class="modal modal-open" id="worker-env-modal">
        <div class="modal-box">
          <h3 class="mb-3 text-[13px] font-medium text-[var(--text-title)]">Set worker env var</h3>
          <.form
            for={%{}}
            as={:worker_env}
            phx-submit="set_worker_env"
            phx-target={@myself}
            class="flex flex-col gap-3"
          >
            <Forms.input
              name="worker_env[key]"
              label="Name"
              value=""
              size="sm"
              placeholder="API_TOKEN"
              required
            />
            <Forms.input
              type="password"
              name="worker_env[value]"
              label="Value"
              value=""
              size="sm"
              autocomplete="off"
              required
            />
            <Forms.checkbox
              name="worker_env[secret]"
              value="true"
              label="Secret — encrypt at rest and redact from logs"
            />
            <p :if={@worker_env_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
              {@worker_env_error}
            </p>
            <div class="modal-action">
              <Core.button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="close_worker_env_modal"
                phx-target={@myself}
              >
                Cancel
              </Core.button>
              <Core.button type="submit" variant="primary" size="sm">Save</Core.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_worker_env_modal" phx-target={@myself}></div>
      </div>
    </div>
    """
  end
end
