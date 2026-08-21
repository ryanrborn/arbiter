defmodule ArbiterWeb.WorkspaceDetail.RoutingAdaptersComponent do
  @moduledoc """
  `routing.adapters` — the ordered list of partial agent-config overrides the
  `round_robin` policy cycles per dispatch.

  The list is rewritten whole on every add/remove; the index shown in each row
  is the position `RoundRobin` cycles through, so it is the removal key.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  @impl true
  def mount(socket), do: {:ok, assign(socket, :routing_adapter_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign(
       socket,
       :routing_adapters,
       socket.assigns.workspace |> routing_adapters_raw() |> Enum.with_index()
     )}
  end

  @impl true
  def handle_event("add_routing_adapter", %{"adapter" => params}, socket) do
    entry = routing_entry_fields(params)

    if entry == %{} do
      {:noreply, assign(socket, :routing_adapter_error, "Adapter entry can't be empty.")}
    else
      write(socket, routing_adapters_raw(socket.assigns.workspace) ++ [entry])
    end
  end

  def handle_event("rm_routing_adapter", %{"index" => index}, socket) do
    adapters =
      socket.assigns.workspace
      |> routing_adapters_raw()
      |> List.delete_at(String.to_integer(index))

    write(socket, adapters)
  end

  defp write(socket, adapters) do
    patch = %{"routing" => %{"adapters" => adapters}}

    case patch_config(socket.assigns.workspace, patch, []) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:routing_adapter_error, nil)
         |> assign(:routing_adapters, ws |> routing_adapters_raw() |> Enum.with_index())}

      {:error, msg} ->
        {:noreply, assign(socket, :routing_adapter_error, msg)}
    end
  end

  defp routing_adapters_raw(ws) do
    case cfg(ws, ["routing", "adapters"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="border-t border-base-300 pt-3">
      <h3 class="font-semibold text-sm flex items-center gap-2">
        Round-robin adapters
        <span class="text-base-content/40 font-normal">({length(@routing_adapters)})</span>
      </h3>
      <p class="text-xs text-base-content/50 mt-1">
        <code>routing.adapters</code>
        — ordered list of agent-config overrides cycled per dispatch (<code>round_robin</code> policy only).
      </p>

      <ul :if={@routing_adapters != []} id="routing-adapters" class="flex flex-col gap-1.5 mt-2">
        <li
          :for={{adapter, index} <- @routing_adapters}
          class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
        >
          <span class="badge badge-sm badge-ghost">{index}</span>
          <span class="text-xs font-mono text-base-content/60 flex-1">
            {routing_entry_summary(adapter)}
          </span>
          <button
            type="button"
            phx-click="rm_routing_adapter"
            phx-target={@myself}
            phx-value-index={index}
            class="btn btn-ghost btn-xs text-error shrink-0"
            aria-label={"Remove adapter #{index}"}
            data-confirm={"Remove routing.adapters[#{index}]?"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>

      <.form
        for={%{}}
        as={:adapter}
        phx-submit="add_routing_adapter"
        phx-target={@myself}
        class="flex flex-wrap gap-2 items-start mt-2"
      >
        <input
          type="text"
          name="adapter[model_tier]"
          placeholder="model_tier, e.g. economy"
          class="input input-sm flex-1"
        />
        <input
          type="text"
          name="adapter[thinking]"
          placeholder="thinking, e.g. low"
          class="input input-sm flex-1"
        />
        <input
          type="text"
          name="adapter[model]"
          placeholder="model (raw override, optional)"
          class="input input-sm flex-1"
        />
        <.button type="submit" class="btn btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add
        </.button>
      </.form>
      <p :if={@routing_adapter_error} class="text-sm text-error mt-1">
        {@routing_adapter_error}
      </p>
    </div>
    """
  end
end
