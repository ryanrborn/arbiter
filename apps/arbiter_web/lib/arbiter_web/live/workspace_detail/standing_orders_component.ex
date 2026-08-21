defmodule ArbiterWeb.WorkspaceDetail.StandingOrdersComponent do
  @moduledoc """
  `config.standing_orders` — the short imperative directives surfaced high in
  every worker's `arb prime` briefing.

  Add/remove rewrite the whole list rather than patching into it, because
  `patch_config`'s deep merge has no way to delete a list element.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  @impl true
  def mount(socket), do: {:ok, assign(socket, :order_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :orders, standing_orders(socket.assigns.workspace))}
  end

  @impl true
  def handle_event("add_order", %{"order" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    if text == "" do
      {:noreply, assign(socket, :order_error, "Standing order text can't be empty.")}
    else
      orders = standing_orders(socket.assigns.workspace) ++ [text]
      write(socket, orders)
    end
  end

  def handle_event("rm_order", %{"index" => index}, socket) do
    orders =
      socket.assigns.workspace
      |> standing_orders()
      |> List.delete_at(String.to_integer(index))

    write(socket, orders)
  end

  defp write(socket, orders) do
    case patch_config(socket.assigns.workspace, %{"standing_orders" => orders}, []) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:order_error, nil)
         |> assign(:orders, standing_orders(ws))}

      {:error, msg} ->
        {:noreply, assign(socket, :order_error, msg)}
    end
  end

  defp standing_orders(ws) do
    case get_in(ws.config || %{}, ["standing_orders"]) do
      list when is_list(list) -> list
      _ -> []
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

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-200 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-clipboard-document-check" class="size-5 text-base-content/60" />
          Standing orders <span class="text-base-content/40 font-normal">({length(@orders)})</span>
        </h2>
        <p class="text-xs text-base-content/50 -mt-1">
          Short imperative directives surfaced high in every worker's <code>arb prime</code> briefing.
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
              phx-target={@myself}
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

        <.form
          for={%{}}
          as={:order}
          phx-submit="add_order"
          phx-target={@myself}
          class="flex gap-2 items-start mt-1"
        >
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
    """
  end
end
