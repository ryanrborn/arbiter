defmodule ArbiterWeb.WorkspaceDetail.RoutingAdaptersComponent do
  @moduledoc """
  `routing.adapters` — the ordered list of partial agent-config overrides the
  `round_robin` policy cycles per dispatch.

  The list is rewritten whole on every add/remove; the index shown in each row
  is the position `RoundRobin` cycles through, so it is the removal key.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

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
    <div id={@id} class={pane_class("routing", @section)}>
      <.rows>
        <.setting_row
          name="Round-robin adapters"
          consequence="routing.adapters — the round_robin policy takes the next one of these per dispatch; every other policy ignores them"
        >
          <:below>
            <ul :if={@routing_adapters != []} id="routing-adapters" class={list_class()}>
              <.list_row :for={{adapter, index} <- @routing_adapters}>
                <span class="w-5 text-[var(--text-label)]">{index}</span>
                <span class="flex-1 truncate text-[var(--text-secondary)]">
                  {routing_entry_summary(adapter)}
                </span>
                <.remove_button
                  label={"Remove adapter #{index}"}
                  phx-click="rm_routing_adapter"
                  phx-target={@myself}
                  phx-value-index={index}
                  data-confirm={"Remove routing.adapters[#{index}]?"}
                />
              </.list_row>
            </ul>

            <.form
              for={%{}}
              as={:adapter}
              phx-submit="add_routing_adapter"
              phx-target={@myself}
              class="mt-2 flex flex-wrap items-center gap-2"
            >
              <Forms.input
                name="adapter[model_tier]"
                value=""
                size="sm"
                placeholder="economy"
                class="flex-1"
              />
              <Forms.input
                name="adapter[thinking]"
                value=""
                size="sm"
                placeholder="low"
                class="flex-1"
              />
              <Forms.input
                name="adapter[model]"
                value=""
                size="sm"
                placeholder="raw model override"
                class="flex-1"
              />
              <Core.button type="submit" size="sm">Add</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>

      <p :if={@routing_adapter_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
        {@routing_adapter_error}
      </p>
    </div>
    """
  end
end
