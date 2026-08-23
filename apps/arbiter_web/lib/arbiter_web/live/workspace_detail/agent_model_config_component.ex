defmodule ArbiterWeb.WorkspaceDetail.AgentModelConfigComponent do
  @moduledoc """
  `agent.config.*` — what model a dispatched worker runs and how it
  authenticates: `model`, the tier → model map, per-thinking-level argv, the
  per-provider tier overrides, and `credentials_ref`.

  The credential field is a **select over the workspace's existing secret
  names** (`secret:<key>`), never a free-text field that could take a raw
  token: secret *values* are write-only and live in their own encrypted
  attribute.

  Every field is an *override* of an adapter default, so a blank field unsets
  rather than writing `""` (which the adapters would happily use as a model
  name). Keys this form doesn't own — `vernacular`, `api_keys` — are siblings
  under `agent.config` and survive the deep merge untouched.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  # The model tiers (`agent.config.tier_models`) and thinking levels
  # (`agent.config.thinking_argv`) every adapter defines. They are only the
  # *baseline* row set: operators routinely add keys of their own (real
  # workspaces carry `tier_models.flagship` and `thinking_argv.xhigh`, neither
  # of which appears anywhere in this codebase), so the rendered rows are the
  # baseline unioned with whatever the workspace actually stores. Hiding an
  # unknown key would leave config only `arb config set` can reach.
  @base_model_tiers ~w[economy standard premium]
  @base_thinking_levels ~w[low medium high]

  # `thinking_argv["none"]` is inert: every adapter's `thinking_argv/1` returns
  # `[]` for "none" before it ever consults the overrides. No row, and the key
  # is left untouched rather than being unset by a blank field.
  @inert_thinking_levels ~w[none]

  @doc """
  The tier keys this workspace renders rows for — the baseline plus every key
  it actually stores (including per-provider sub-maps). Public because the
  parent has no other way to know the row set.
  """
  def model_tiers(ws) do
    stored =
      [config_map(ws, ["agent", "config", "tier_models"])]
      |> Enum.concat(Enum.map(Agents.valid_agent_types(), &provider_tier_models(ws, &1)))
      |> Enum.flat_map(&Map.keys/1)

    order_keys(@base_model_tiers, stored)
  end

  @impl true
  def mount(socket), do: {:ok, assign(socket, :agent_config_error, nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load_derived(socket)}
  end

  defp load_derived(%{assigns: %{workspace: ws}} = socket) do
    socket
    |> assign(:model_tiers, model_tiers(ws))
    |> assign(:thinking_levels, thinking_levels(ws))
    |> assign(:provider_overrides, provider_overrides(ws))
    |> assign(:secret_keys, secret_keys(ws))
  end

  @impl true
  def handle_event("save_agent_config", %{"agent_config" => params}, socket) do
    {patch, unset} =
      agent_config_patch(params, socket.assigns.model_tiers, socket.assigns.thinking_levels)

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws, "Agent config saved.")
         |> assign(:agent_config_error, nil)
         |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :agent_config_error, msg)}
    end
  end

  def handle_event(
        "add_provider_override",
        %{"provider_override" => %{"provider" => provider, "tier" => tier, "model" => model}},
        socket
      ) do
    model = blank_to_nil(model)

    cond do
      provider not in socket.assigns.agent_types ->
        {:noreply, assign(socket, :agent_config_error, "Unknown provider #{inspect(provider)}.")}

      tier not in socket.assigns.model_tiers ->
        {:noreply, assign(socket, :agent_config_error, "Unknown model tier #{inspect(tier)}.")}

      is_nil(model) ->
        {:noreply, assign(socket, :agent_config_error, "Override model can't be empty.")}

      true ->
        patch = %{"agent" => %{"config" => %{provider => %{"tier_models" => %{tier => model}}}}}
        write(socket, patch, [])
    end
  end

  def handle_event("rm_provider_override", %{"provider" => provider, "tier" => tier}, socket) do
    if provider in socket.assigns.agent_types do
      remaining =
        socket.assigns.workspace
        |> provider_tier_models(provider)
        |> Map.delete(tier)

      # Deep-merge can't delete a map key, so the whole sub-map is unset first
      # and the survivors merged back. `provider` comes from the fixed
      # `Agents.valid_agent_types/0` list, so the dotted path can't be widened
      # by a name containing "." (cf. the review_automation.repo_overrides fix).
      patch = %{"agent" => %{"config" => %{provider => %{"tier_models" => remaining}}}}
      write(socket, patch, ["agent.config.#{provider}.tier_models"])
    else
      {:noreply, assign(socket, :agent_config_error, "Unknown provider #{inspect(provider)}.")}
    end
  end

  defp write(socket, patch, unset) do
    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:agent_config_error, nil)
         |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :agent_config_error, msg)}
    end
  end

  defp agent_config_patch(params, model_tiers, thinking_levels) do
    {patch, unset} =
      Enum.reduce([{"model", "model"}, {"credentials_ref", "credentials_ref"}], {%{}, []}, fn
        {field, key}, {patch, unset} ->
          case blank_to_nil(params[field]) do
            nil -> {patch, unset ++ ["agent.config.#{key}"]}
            v -> {Map.put(patch, key, v), unset}
          end
      end)

    {tier_models, unset} =
      Enum.reduce(model_tiers, {%{}, unset}, fn tier, {acc, unset} ->
        case blank_to_nil(params["tier_#{tier}"]) do
          nil -> {acc, unset ++ ["agent.config.tier_models.#{tier}"]}
          v -> {Map.put(acc, tier, v), unset}
        end
      end)

    {thinking_argv, unset} =
      Enum.reduce(thinking_levels, {%{}, unset}, fn level, {acc, unset} ->
        case blank_to_nil(params["thinking_#{level}"]) do
          nil -> {acc, unset ++ ["agent.config.thinking_argv.#{level}"]}
          v -> {Map.put(acc, level, String.split(v, ~r/\s+/, trim: true)), unset}
        end
      end)

    agent_config =
      patch
      |> maybe_put_map("tier_models", tier_models)
      |> maybe_put_map("thinking_argv", thinking_argv)

    {%{"agent" => %{"config" => agent_config}}, unset}
  end

  defp thinking_levels(ws) do
    stored = ws |> config_map(["agent", "config", "thinking_argv"]) |> Map.keys()

    @base_thinking_levels
    |> order_keys(stored)
    |> Enum.reject(&(&1 in @inert_thinking_levels))
  end

  defp order_keys(base, stored) do
    extras = stored |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 in base)) |> Enum.uniq()
    base ++ Enum.sort(extras)
  end

  # Per-provider tier overrides flattened for display:
  # `agent.config.<provider>.tier_models.<tier>` → `{provider, tier, model}`,
  # ordered by the provider precedence list then by tier.
  defp provider_overrides(ws) do
    tier_order = model_tiers(ws)

    for provider <- Agents.valid_agent_types(),
        {tier, model} <-
          Enum.sort_by(provider_tier_models(ws, provider), &tier_rank(&1, tier_order)),
        is_binary(model),
        do: {provider, tier, model}
  end

  defp tier_rank({tier, _model}, tier_order) do
    Enum.find_index(tier_order, &(&1 == tier)) || length(tier_order)
  end

  defp provider_tier_models(ws, provider) do
    config_map(ws, ["agent", "config", provider, "tier_models"])
  end

  defp agent_cfg(ws, key) do
    case cfg(ws, ["agent", "config", key]) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp tier_model_value(ws, tier) do
    case cfg(ws, ["agent", "config", "tier_models"]) do
      %{} = m ->
        case Map.get(m, tier) do
          model when is_binary(model) -> model
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp thinking_argv_value(ws, level) do
    case cfg(ws, ["agent", "config", "thinking_argv"]) do
      %{} = m ->
        case Map.get(m, level) do
          argv when is_list(argv) -> argv |> Enum.filter(&is_binary/1) |> Enum.join(" ")
          argv when is_binary(argv) -> argv
          _ -> ""
        end

      _ ->
        ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("agent_models", @section)}>
      <.form for={%{}} as={:agent_config} phx-submit="save_agent_config" phx-target={@myself}>
        <.rows>
          <.setting_row
            name="Model"
            consequence="agent.config.model — every dispatch runs this model; blank lets the agent CLI pick its own default"
          >
            <:control>
              <Forms.input
                name="agent_config[model]"
                value={agent_cfg(@workspace, "model")}
                size="sm"
                placeholder="CLI default"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            name="Credentials"
            consequence="agent.config.credentials_ref — which stored secret the agent authenticates with; add one under Secrets first"
          >
            <:control>
              <Forms.select
                name="agent_config[credentials_ref]"
                options={
                  credentials_ref_options(@secret_keys, agent_cfg(@workspace, "credentials_ref"))
                }
                value={agent_cfg(@workspace, "credentials_ref")}
                size="sm"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            :for={tier <- @model_tiers}
            name={"Tier model — #{tier}"}
            consequence={"agent.config.tier_models.#{tier} — routing that lands on the #{tier} tier runs this model; blank falls back to the adapter's own"}
          >
            <:control>
              <Forms.input
                name={"agent_config[tier_#{tier}]"}
                value={tier_model_value(@workspace, tier)}
                size="sm"
                placeholder="adapter default"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            :for={level <- @thinking_levels}
            name={"Thinking argv — #{level}"}
            consequence={"agent.config.thinking_argv.#{level} — appended to the CLI when routing asks for #{level} thinking; blank uses the adapter's own flag"}
          >
            <:control>
              <Forms.input
                name={"agent_config[thinking_#{level}]"}
                value={thinking_argv_value(@workspace, level)}
                size="sm"
                placeholder="--effort medium"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>
        </.rows>

        <div class="mt-3 flex items-center gap-3">
          <Core.button type="submit" variant="primary" size="sm">Save agent config</Core.button>
          <p :if={@agent_config_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
            {@agent_config_error}
          </p>
        </div>
      </.form>

      <.rows>
        <.setting_row
          name="Per-provider model overrides"
          consequence="scopes a tier to one provider in a multi-provider pool, where the flat tier models above would apply to every adapter"
        >
          <:below>
            <ul :if={@provider_overrides != []} id="provider-overrides" class={list_class()}>
              <.list_row :for={{provider, tier, model} <- @provider_overrides}>
                <span class="flex-1 truncate">{provider} · {tier}</span>
                <span class={value_chip()}>
                  {model}
                </span>
                <.remove_button
                  label={"Remove #{provider} #{tier} model override"}
                  phx-click="rm_provider_override"
                  phx-target={@myself}
                  phx-value-provider={provider}
                  phx-value-tier={tier}
                  data-confirm={"Remove the #{provider} #{tier} model override?"}
                />
              </.list_row>
            </ul>

            <.form
              for={%{}}
              as={:provider_override}
              phx-submit="add_provider_override"
              phx-target={@myself}
              class="mt-2 flex items-center gap-2"
            >
              <Forms.select
                name="provider_override[provider]"
                options={@agent_types}
                size="sm"
                class="w-[130px]"
              />
              <Forms.select
                name="provider_override[tier]"
                options={@model_tiers}
                size="sm"
                class="w-[130px]"
              />
              <Forms.input
                name="provider_override[model]"
                value=""
                size="sm"
                placeholder="gemini-3-pro"
                class="flex-1"
                required
              />
              <Core.button type="submit" size="sm">Add</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>
    </div>
    """
  end
end
