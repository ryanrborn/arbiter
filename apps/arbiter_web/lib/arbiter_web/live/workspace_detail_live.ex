defmodule ArbiterWeb.WorkspaceDetailLive do
  @moduledoc """
  Workspace detail + editor at `/workspaces/:id`.

  Surfaces every config section a non-CLI operator needs to onboard and run a
  workspace: tracker, merger, agent + review-agent, routing policy, review gate,
  standing orders, and secrets. The page is fully editable:

    * **Configuration** — a single form for the high-level enums (agent type,
      tracker type, merger strategy, routing policy, review required) patched
      atomically through the `:patch_config` action so siblings are preserved.
    * **Standing orders** — add/remove individual orders without clobbering the
      list (`config.standing_orders`).
    * **Secrets** — the *names* of configured secrets only; set/rm via a modal.
      Plaintext values are never echoed back to the page — the form posts a
      value, the server encrypts it, and only the key names return.

  All writes go through Ash actions directly (same VM as the API controller),
  so the server-side `ValidateConfig` guardrails apply identically.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Agents
  alias Arbiter.Agents.Routing
  alias Arbiter.Tasks.Workspace

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Ash.get(Workspace, id) do
      {:ok, ws} ->
        {:ok,
         socket
         |> assign(:workspace, ws)
         |> assign(:not_found, false)
         |> assign(:secret_modal, false)
         |> assign(:secret_error, nil)
         |> assign(:config_error, nil)
         |> assign(:order_error, nil)
         |> assign(:tracker_types, Workspace.valid_tracker_types())
         |> assign(:merger_strategies, Workspace.valid_merger_strategies())
         |> assign(:agent_types, Agents.valid_agent_types())
         |> assign(:routing_policies, Routing.valid_policies())
         |> load_derived()}

      _ ->
        {:ok, assign(socket, workspace: nil, not_found: true)}
    end
  end

  # ---- config form (enums) ----

  @impl true
  def handle_event("save_config", %{"config" => params}, socket) do
    patch = %{
      "agent" => %{"type" => params["agent_type"]},
      "tracker" => %{"type" => params["tracker_type"]},
      "merge" => %{"strategy" => params["merger_strategy"]},
      "routing" => %{"policy" => params["routing_policy"]},
      "review" => %{"required" => params["review_required"] == "true"}
    }

    case patch_config(socket.assigns.workspace, patch, []) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workspace, ws)
         |> assign(:config_error, nil)
         |> load_derived()
         |> put_flash(:info, "Configuration saved.")}

      {:error, msg} ->
        {:noreply, assign(socket, :config_error, msg)}
    end
  end

  # ---- standing orders ----

  def handle_event("add_order", %{"order" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    if text == "" do
      {:noreply, assign(socket, :order_error, "Standing order text can't be empty.")}
    else
      orders = standing_orders(socket.assigns.workspace) ++ [text]

      case patch_config(socket.assigns.workspace, %{"standing_orders" => orders}, []) do
        {:ok, ws} ->
          {:noreply,
           socket
           |> assign(:workspace, ws)
           |> assign(:order_error, nil)
           |> load_derived()}

        {:error, msg} ->
          {:noreply, assign(socket, :order_error, msg)}
      end
    end
  end

  def handle_event("rm_order", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    orders = standing_orders(socket.assigns.workspace) |> List.delete_at(idx)

    case patch_config(socket.assigns.workspace, %{"standing_orders" => orders}, []) do
      {:ok, ws} ->
        {:noreply, socket |> assign(:workspace, ws) |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :order_error, msg)}
    end
  end

  # ---- secrets ----

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
             |> assign(:workspace, ws)
             |> assign(secret_modal: false, secret_error: nil)
             |> load_derived()
             |> put_flash(:info, "Secret #{key} stored.")}

          {:error, msg} ->
            {:noreply, assign(socket, :secret_error, msg)}
        end
    end
  end

  def handle_event("rm_secret", %{"key" => key}, socket) do
    case set_secrets(socket.assigns.workspace, %{key => nil}) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workspace, ws)
         |> load_derived()
         |> put_flash(:info, "Secret #{key} removed.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # ---- Ash write helpers ----

  defp patch_config(ws, patch, unset_paths) do
    case Ash.update(ws, %{patch: patch, unset_paths: unset_paths}, action: :patch_config) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, error_message(err)}
    end
  end

  defp set_secrets(ws, secrets) do
    case Ash.update(ws, %{secrets: secrets}, action: :update) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, error_message(err)}
    end
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map_join("; ", &Exception.message/1)
  end

  defp error_message(err), do: Exception.message(err)

  # ---- derived view state ----

  defp load_derived(%{assigns: %{workspace: ws}} = socket) do
    socket
    |> assign(:secret_keys, ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort())
    |> assign(:orders, standing_orders(ws))
  end

  defp standing_orders(ws) do
    case get_in(ws.config || %{}, ["standing_orders"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp cfg(ws, path, default \\ nil) do
    case get_in(ws.config || %{}, path) do
      nil -> default
      v -> v
    end
  end

  # Agent type may be a string or a multi-provider pool list; the form edits the
  # scalar case, so render a list as a comma-joined read-only hint.
  defp agent_type_value(ws) do
    case cfg(ws, ["agent", "type"]) do
      t when is_binary(t) -> t
      _ -> "claude"
    end
  end

  defp order_text(order) when is_binary(order), do: order

  defp order_text(%{"title" => title} = order) do
    case order["detail"] do
      d when is_binary(d) and d != "" -> "#{title} — #{d}"
      _ -> title
    end
  end

  defp order_text(order), do: inspect(order)

  defp review_required?(ws), do: cfg(ws, ["review", "required"]) in [true, "true"]

  # ---- render ----

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-3xl mx-auto space-y-4">
        <.empty_state id="ws-404" icon="hero-building-office-2">
          Workspace not found.
        </.empty_state>
        <.link navigate={~p"/workspaces"} class="link link-primary text-sm">← All workspaces</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-4xl mx-auto space-y-6">
        <div>
          <.link navigate={~p"/workspaces"} class="link link-hover text-sm text-base-content/60">
            ← All workspaces
          </.link>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2 mt-1">
            <span class="badge badge-ghost font-mono">{@workspace.prefix}</span>
            {@workspace.name}
          </h1>
          <p class="text-xs text-base-content/50 mt-1 font-mono">{@workspace.id}</p>
          <p :if={@workspace.description not in [nil, ""]} class="text-sm text-base-content/70 mt-1">
            {@workspace.description}
          </p>
        </div>

        <%!-- Configuration --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" /> Configuration
            </h2>
            <.form
              for={%{}}
              as={:config}
              phx-submit="save_config"
              class="grid sm:grid-cols-2 gap-x-4"
            >
              <.input
                type="select"
                name="config[agent_type]"
                label="Agent type"
                options={Enum.map(@agent_types, &{&1, &1})}
                value={agent_type_value(@workspace)}
              />
              <.input
                type="select"
                name="config[tracker_type]"
                label="Tracker type"
                options={Enum.map(@tracker_types, &{&1, &1})}
                value={cfg(@workspace, ["tracker", "type"], "none")}
              />
              <.input
                type="select"
                name="config[merger_strategy]"
                label="Merger strategy"
                options={Enum.map(@merger_strategies, &{&1, &1})}
                value={cfg(@workspace, ["merge", "strategy"], "direct")}
              />
              <.input
                type="select"
                name="config[routing_policy]"
                label="Routing policy"
                options={Enum.map(@routing_policies, &{&1, &1})}
                value={cfg(@workspace, ["routing", "policy"], "static")}
              />
              <label class="fieldset flex items-center gap-2 mt-6">
                <input type="hidden" name="config[review_required]" value="false" />
                <input
                  type="checkbox"
                  name="config[review_required]"
                  value="true"
                  checked={review_required?(@workspace)}
                  class="toggle toggle-sm toggle-primary"
                />
                <span class="text-sm">Code review required before merge</span>
              </label>
              <div class="sm:col-span-2 flex items-center gap-3 mt-2">
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Save configuration
                </.button>
                <p :if={@config_error} class="text-sm text-error">{@config_error}</p>
              </div>
            </.form>
            <p class="text-xs text-base-content/50">
              Adapter-specific details (hosts, owner/repo, <code>credentials_ref</code>) are set with <code>arb config set</code>. Reference a secret below via <code>secret:&lt;key&gt;</code>.
            </p>
          </div>
        </section>

        <%!-- Standing orders --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold flex items-center gap-2">
              <.icon name="hero-clipboard-document-check" class="size-5 text-base-content/60" />
              Standing orders
              <span class="text-base-content/40 font-normal">({length(@orders)})</span>
            </h2>
            <p class="text-xs text-base-content/50 -mt-1">
              Short imperative directives surfaced high in every worker's <code>arb prime</code>
              briefing.
            </p>

            <ul :if={@orders != []} id="standing-orders" class="flex flex-col gap-1.5">
              <li
                :for={{order, idx} <- Enum.with_index(@orders)}
                class="flex items-start gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
              >
                <span class="text-xs text-base-content/40 font-mono mt-0.5 w-5 shrink-0">
                  {idx + 1}.
                </span>
                <span class="text-sm flex-1 min-w-0 break-words">{order_text(order)}</span>
                <button
                  type="button"
                  phx-click="rm_order"
                  phx-value-index={idx}
                  class="btn btn-ghost btn-xs text-error shrink-0"
                  aria-label="Remove standing order"
                  data-confirm="Remove this standing order?"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </li>
            </ul>

            <p :if={@orders == []} class="text-sm text-base-content/50 italic">
              No standing orders set.
            </p>

            <.form for={%{}} as={:order} phx-submit="add_order" class="flex gap-2 items-start mt-1">
              <input
                type="text"
                name="order[text]"
                placeholder="e.g. Check your inbox at the start of every step"
                class="input input-sm flex-1"
              />
              <.button type="submit" class="btn btn-sm">
                <.icon name="hero-plus" class="size-4" /> Add
              </.button>
            </.form>
            <p :if={@order_error} class="text-sm text-error">{@order_error}</p>
          </div>
        </section>

        <%!-- Secrets --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <div class="flex items-center justify-between gap-2">
              <h2 class="font-semibold flex items-center gap-2">
                <.icon name="hero-key" class="size-5 text-base-content/60" /> Secrets
                <span class="text-base-content/40 font-normal">({length(@secret_keys)})</span>
              </h2>
              <.button phx-click="open_secret_modal" class="btn btn-sm">
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
          </div>
        </section>
      </div>

      <%!-- Set-secret modal --%>
      <div :if={@secret_modal} class="modal modal-open" id="secret-modal">
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-3">Set secret</h3>
          <.form for={%{}} as={:secret} phx-submit="set_secret" class="space-y-2">
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
              <.button type="button" phx-click="close_secret_modal" class="btn btn-sm btn-ghost">
                Cancel
              </.button>
              <.button type="submit" variant="primary" class="btn btn-sm btn-primary">Store</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_secret_modal"></div>
      </div>
    </Layouts.app>
    """
  end
end
