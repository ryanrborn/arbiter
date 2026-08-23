defmodule ArbiterWeb.WorkspaceDetail.RoutingRulesComponent do
  @moduledoc """
  `routing.rules` — a per-tier agent-config override keyed by priority
  (`P0`..`P4`) or difficulty (`D0`..`D4`), depending on `routing.policy`.

  Saving a key that already exists replaces that rule wholesale: the key is
  unset first, then the new entry merged in, so a field dropped from the form
  is actually dropped rather than surviving the deep merge.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

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
    <div id={@id} class={pane_class("routing", @section)}>
      <.rows>
        <.setting_row
          name="Routing rules"
          consequence="routing.rules — keyed by priority (P0-P4) or difficulty (D0-D4) per the routing policy; saving a key replaces that rule wholesale"
        >
          <:below>
            <ul :if={@routing_rules != []} id="routing-rules" class={list_class()}>
              <.list_row :for={{key, rule} <- @routing_rules}>
                <span class="w-10 font-medium">{key}</span>
                <span class="flex-1 truncate text-[var(--text-secondary)]">
                  {routing_entry_summary(rule)}
                </span>
                <.remove_button
                  label={"Remove rule #{key}"}
                  phx-click="rm_routing_rule"
                  phx-target={@myself}
                  phx-value-key={key}
                  data-confirm={"Remove the routing.rules.#{key} entry?"}
                />
              </.list_row>
            </ul>

            <.form
              for={%{}}
              as={:rule}
              phx-submit="save_routing_rule"
              phx-target={@myself}
              class="mt-2 flex flex-wrap items-center gap-2"
            >
              <Forms.input
                name="rule[key]"
                value=""
                size="sm"
                placeholder="D4 / P0"
                class="w-[90px]"
                required
              />
              <Forms.input
                name="rule[model_tier]"
                value=""
                size="sm"
                placeholder="premium"
                class="flex-1"
              />
              <Forms.input name="rule[thinking]" value="" size="sm" placeholder="high" class="flex-1" />
              <Forms.input
                name="rule[model]"
                value=""
                size="sm"
                placeholder="raw model override"
                class="flex-1"
              />
              <Core.button type="submit" size="sm">Add / replace</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>

      <p :if={@routing_rule_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
        {@routing_rule_error}
      </p>
    </div>
    """
  end
end
