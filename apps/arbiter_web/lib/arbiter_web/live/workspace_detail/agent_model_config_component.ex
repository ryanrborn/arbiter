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

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents

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
    <section id={@id} class="card bg-base-200 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="size-5 text-base-content/60" /> Agent model config
        </h2>
        <p class="text-xs text-base-content/50 -mt-1">
          <code>agent.config.*</code>
          — what model a dispatched worker runs and how it authenticates. Blank unsets the
          override and lets the adapter default apply.
        </p>

        <.form
          for={%{}}
          as={:agent_config}
          phx-submit="save_agent_config"
          phx-target={@myself}
          class="grid sm:grid-cols-2 gap-x-4"
        >
          <.input
            type="text"
            name="agent_config[model]"
            label="Model (agent.config.model)"
            placeholder="default: let the CLI pick"
            value={agent_cfg(@workspace, "model")}
          />
          <.input
            type="select"
            name="agent_config[credentials_ref]"
            label="Credentials (agent.config.credentials_ref)"
            options={credentials_ref_options(@secret_keys, agent_cfg(@workspace, "credentials_ref"))}
            value={agent_cfg(@workspace, "credentials_ref")}
          />
          <.input
            :for={tier <- @model_tiers}
            type="text"
            name={"agent_config[tier_#{tier}]"}
            label={"Tier model — #{tier} (agent.config.tier_models.#{tier})"}
            placeholder="adapter default"
            value={tier_model_value(@workspace, tier)}
          />
          <.input
            :for={level <- @thinking_levels}
            type="text"
            name={"agent_config[thinking_#{level}]"}
            label={"Thinking argv — #{level} (agent.config.thinking_argv.#{level})"}
            placeholder="adapter default, e.g. --effort medium"
            value={thinking_argv_value(@workspace, level)}
          />
          <div class="sm:col-span-2 flex items-center gap-3 mt-2">
            <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
              Save agent config
            </.button>
            <p :if={@agent_config_error} class="text-sm text-error">{@agent_config_error}</p>
          </div>
        </.form>

        <div class="border-t border-base-300 pt-3">
          <h3 class="font-semibold text-sm flex items-center gap-2">
            Per-provider model overrides
            <span class="text-base-content/40 font-normal">({length(@provider_overrides)})</span>
          </h3>
          <p class="text-xs text-base-content/50 mt-1">
            <code>agent.config.&lt;provider&gt;.tier_models.&lt;tier&gt;</code>
            — scopes a tier to one provider in a multi-provider pool, where the flat
            <code>tier_models</code>
            above would otherwise apply to every adapter.
          </p>

          <ul
            :if={@provider_overrides != []}
            id="provider-overrides"
            class="flex flex-col gap-1.5 mt-2"
          >
            <li
              :for={{provider, tier, model} <- @provider_overrides}
              class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
            >
              <code class="text-sm flex-1">{provider} · {tier}</code>
              <span class="badge badge-sm badge-ghost font-mono">{model}</span>
              <button
                type="button"
                phx-click="rm_provider_override"
                phx-target={@myself}
                phx-value-provider={provider}
                phx-value-tier={tier}
                class="btn btn-ghost btn-xs text-error shrink-0"
                aria-label={"Remove #{provider} #{tier} model override"}
                data-confirm={"Remove the #{provider} #{tier} model override?"}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>

          <.form
            for={%{}}
            as={:provider_override}
            phx-submit="add_provider_override"
            phx-target={@myself}
            class="flex gap-2 items-start mt-2"
          >
            <select name="provider_override[provider]" class="select select-sm">
              <option :for={provider <- @agent_types} value={provider}>{provider}</option>
            </select>
            <select name="provider_override[tier]" class="select select-sm">
              <option :for={tier <- @model_tiers} value={tier}>{tier}</option>
            </select>
            <input
              type="text"
              name="provider_override[model]"
              placeholder="model, e.g. gemini-3-pro"
              class="input input-sm flex-1"
              required
            />
            <.button type="submit" class="btn btn-sm">
              <.icon name="hero-plus" class="size-4" /> Add
            </.button>
          </.form>
        </div>
      </div>
    </section>
    """
  end
end
