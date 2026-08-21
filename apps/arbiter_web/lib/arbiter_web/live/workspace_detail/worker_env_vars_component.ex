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

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Tasks.Workspace

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
    <section id={@id} class="card bg-base-200 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="font-semibold flex items-center gap-2">
            <.icon name="hero-variable" class="size-5 text-base-content/60" /> Worker env vars
            <span class="text-base-content/40 font-normal">({length(@worker_env_keys)})</span>
          </h2>
          <.button phx-click="open_worker_env_modal" phx-target={@myself} class="btn btn-sm">
            <.icon name="hero-plus" class="size-4" /> Set variable
          </.button>
        </div>
        <p class="text-xs text-base-content/50 -mt-1">
          Injected into every worker's subprocess environment. Mark a value <em>secret</em>
          to encrypt it and redact it from worker logs and the dashboard.
        </p>

        <ul :if={@worker_env_keys != []} id="worker-env-keys" class="flex flex-col gap-1.5">
          <li
            :for={entry <- @worker_env_keys}
            class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
          >
            <.icon
              name={if entry.secret?, do: "hero-lock-closed", else: "hero-lock-open"}
              class="size-4 text-base-content/40 shrink-0"
            />
            <code class="text-sm shrink-0">{entry.name}</code>
            <span class="text-base-content/30">=</span>
            <code class="text-sm flex-1 truncate text-base-content/70">
              {worker_env_display(entry, @worker_env_values, @revealed_worker_env)}
            </code>
            <button
              :if={entry.secret? and not MapSet.member?(@revealed_worker_env, entry.name)}
              type="button"
              phx-click="reveal_worker_env"
              phx-target={@myself}
              phx-value-key={entry.name}
              class="btn btn-ghost btn-xs shrink-0"
              aria-label="Reveal value"
            >
              <.icon name="hero-eye" class="size-4" />
            </button>
            <button
              :if={entry.secret? and MapSet.member?(@revealed_worker_env, entry.name)}
              type="button"
              phx-click="hide_worker_env"
              phx-target={@myself}
              phx-value-key={entry.name}
              class="btn btn-ghost btn-xs shrink-0"
              aria-label="Hide value"
            >
              <.icon name="hero-eye-slash" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="toggle_worker_env_secret"
              phx-target={@myself}
              phx-value-key={entry.name}
              class={[
                "badge badge-sm cursor-pointer shrink-0",
                entry.secret? && "badge-warning",
                !entry.secret? && "badge-ghost"
              ]}
              title="Toggle secret"
            >
              {if entry.secret?, do: "secret", else: "plain"}
            </button>
            <button
              type="button"
              phx-click="rm_worker_env"
              phx-target={@myself}
              phx-value-key={entry.name}
              class="btn btn-ghost btn-xs text-error shrink-0"
              aria-label="Remove worker env var"
              data-confirm={"Remove worker env var #{entry.name}?"}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>

        <p :if={@worker_env_keys == []} class="text-sm text-base-content/50 italic">
          No worker env vars set.
        </p>

        <%!-- Set-worker-env modal — see the note on the secrets modal for why
             it renders inside the section. --%>
        <div :if={@worker_env_modal} class="modal modal-open" id="worker-env-modal">
          <div class="modal-box">
            <h3 class="font-semibold text-lg mb-3">Set worker env var</h3>
            <.form
              for={%{}}
              as={:worker_env}
              phx-submit="set_worker_env"
              phx-target={@myself}
              class="space-y-2"
            >
              <.input name="worker_env[key]" label="Name" value="" placeholder="API_TOKEN" required />
              <.input
                type="password"
                name="worker_env[value]"
                label="Value"
                value=""
                autocomplete="off"
                required
              />
              <label class="flex items-center gap-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="worker_env[secret]"
                  value="true"
                  class="checkbox checkbox-sm"
                /> Secret — encrypt at rest and redact from logs
              </label>
              <p :if={@worker_env_error} class="text-sm text-error">{@worker_env_error}</p>
              <div class="modal-action">
                <.button
                  type="button"
                  phx-click="close_worker_env_modal"
                  phx-target={@myself}
                  class="btn btn-sm btn-ghost"
                >
                  Cancel
                </.button>
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Save
                </.button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_worker_env_modal" phx-target={@myself}></div>
        </div>
      </div>
    </section>
    """
  end
end
