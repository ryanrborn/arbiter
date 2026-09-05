defmodule ArbiterWeb.WorkspaceDetail.StandingOrdersComponent do
  @moduledoc """
  `config.standing_orders` — coordinator-facing directives surfaced in
  `arb prime`. They are never injected into any worker prompt; put
  worker-facing instructions in the repo's `CLAUDE.md` instead.

  Add/remove rewrite the whole list rather than patching into it, because
  `patch_config`'s deep merge has no way to delete a list element.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms

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
    <div id={@id} class={pane_class("standing_orders", @section)}>
      <.rows>
        <.setting_row
          name="Standing orders"
          consequence="surfaced in arb prime, the coordinator's briefing — never injected into any worker prompt"
        >
          <:below>
            <ul :if={@orders != []} id="standing-orders" class={list_class()}>
              <.list_row :for={{order, idx} <- Enum.with_index(@orders)} class="items-start">
                <span class="mt-px w-5 shrink-0 text-[var(--text-label)]">{idx + 1}.</span>
                <span class="min-w-0 flex-1 break-words">{order_text(order)}</span>
                <.remove_button
                  label="Remove standing order"
                  phx-click="rm_order"
                  phx-target={@myself}
                  phx-value-index={idx}
                  data-confirm="Remove this standing order?"
                />
              </.list_row>
            </ul>

            <Feedback.empty_state
              :if={@orders == []}
              icon="hero-clipboard-document-check"
              detail="standing_orders is empty"
            >
              No standing orders — arb prime shows the default briefing only.
            </Feedback.empty_state>

            <.form
              for={%{}}
              as={:order}
              phx-submit="add_order"
              phx-target={@myself}
              class="mt-2 flex items-center gap-2"
            >
              <Forms.input
                name="order[text]"
                value=""
                size="sm"
                mono={false}
                placeholder="Check your inbox at the start of every step"
                class="flex-1"
              />
              <Core.button type="submit" size="sm">Add</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>

      <p :if={@order_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">{@order_error}</p>
    </div>
    """
  end
end
