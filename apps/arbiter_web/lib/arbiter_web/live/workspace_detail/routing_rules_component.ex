defmodule ArbiterWeb.WorkspaceDetail.RoutingRulesComponent do
  @moduledoc """
  `routing.rules` — a per-tier agent-config override keyed by priority
  (`P0`..`P4`) or difficulty (`D0`..`D4`), depending on `routing.policy`.

  Saving a key that already exists replaces that rule wholesale: the key is
  unset first, then the new entry merged in, so a field dropped from the form
  is actually dropped rather than surviving the deep merge.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  @impl true
  def mount(socket), do: {:ok, assign(socket, :routing_rule_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :routing_rules, routing_rules(socket.assigns.workspace))}
  end

  @impl true
  def handle_event("save_routing_rule", %{"rule" => params}, socket) do
    key = params["key"] |> to_string() |> String.trim()

    if key == "" do
      {:noreply, assign(socket, :routing_rule_error, "Rule key can't be empty.")}
    else
      rule = routing_entry_fields(params)
      patch = maybe_put_map(%{}, "routing", maybe_put_map(%{}, "rules", %{key => rule}))
      write(socket, patch, ["routing.rules.#{key}"])
    end
  end

  def handle_event("rm_routing_rule", %{"key" => key}, socket) do
    write(socket, %{}, ["routing.rules.#{key}"])
  end

  defp write(socket, patch, unset) do
    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:routing_rule_error, nil)
         |> assign(:routing_rules, routing_rules(ws))}

      {:error, msg} ->
        {:noreply, assign(socket, :routing_rule_error, msg)}
    end
  end

  # `routing.rules` sorted by tier key ("D0".."D4" / "P0".."P4" sort
  # naturally as strings; anything else falls in alongside).
  defp routing_rules(ws) do
    case cfg(ws, ["routing", "rules"]) do
      m when is_map(m) ->
        m
        |> Enum.filter(fn {k, v} -> is_binary(k) and is_map(v) end)
        |> Enum.sort_by(&elem(&1, 0))

      _ ->
        []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="border-t border-base-300 pt-3">
      <h3 class="font-semibold text-sm flex items-center gap-2">
        Routing rules <span class="text-base-content/40 font-normal">({length(@routing_rules)})</span>
      </h3>
      <p class="text-xs text-base-content/50 mt-1">
        <code>routing.rules</code>
        — per-tier override, keyed by priority (<code>P0</code>-<code>P4</code>) or difficulty
        (<code>D0</code>-<code>D4</code>) depending on the routing policy above. Saving a key
        that already exists replaces that rule wholesale.
      </p>

      <ul :if={@routing_rules != []} id="routing-rules" class="flex flex-col gap-1.5 mt-2">
        <li
          :for={{key, rule} <- @routing_rules}
          class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
        >
          <code class="text-sm font-semibold">{key}</code>
          <span class="text-xs font-mono text-base-content/60 flex-1">
            {routing_entry_summary(rule)}
          </span>
          <button
            type="button"
            phx-click="rm_routing_rule"
            phx-target={@myself}
            phx-value-key={key}
            class="btn btn-ghost btn-xs text-error shrink-0"
            aria-label={"Remove rule #{key}"}
            data-confirm={"Remove the routing.rules.#{key} entry?"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>

      <.form
        for={%{}}
        as={:rule}
        phx-submit="save_routing_rule"
        phx-target={@myself}
        class="flex flex-wrap gap-2 items-start mt-2"
      >
        <input
          type="text"
          name="rule[key]"
          placeholder="D4 / P0"
          class="input input-sm w-24"
          required
        />
        <input
          type="text"
          name="rule[model_tier]"
          placeholder="model_tier, e.g. premium"
          class="input input-sm flex-1"
        />
        <input
          type="text"
          name="rule[thinking]"
          placeholder="thinking, e.g. high"
          class="input input-sm flex-1"
        />
        <input
          type="text"
          name="rule[model]"
          placeholder="model (raw override, optional)"
          class="input input-sm flex-1"
        />
        <.button type="submit" class="btn btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add / replace
        </.button>
      </.form>
      <p :if={@routing_rule_error} class="text-sm text-error mt-1">
        {@routing_rule_error}
      </p>
    </div>
    """
  end
end
