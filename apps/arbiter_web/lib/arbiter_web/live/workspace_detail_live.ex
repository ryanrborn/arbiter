defmodule ArbiterWeb.WorkspaceDetailLive do
  @moduledoc """
  Workspace detail + editor at `/workspaces/:id`.

  Surfaces every config section a non-CLI operator needs to onboard and run a
  workspace: tracker, merger, agent + review-agent, routing policy, review gate,
  standing orders, and secrets. The page is fully editable:

    * **Configuration** — a single form for the high-level enums (agent /
      review-agent provider pools as checkbox groups, tracker type, merger
      strategy, routing policy, review required), patched atomically through
      the `:patch_config` action so siblings (e.g. `agent.config`,
      `agent.security`) are preserved. The resolved security posture is
      surfaced above the security editor below.
    * **Agent model config** (`agent.config.*`) — `model`, the tier → model
      map, per-thinking-level argv, per-provider tier overrides, and
      `credentials_ref`. The credential field is a **select over the
      workspace's existing secret names** (`secret:<key>`), never a free-text
      field that could take a raw token: secret *values* are write-only and
      live in their own encrypted attribute.
    * **Advanced / security** (`agent.security.*`) — deliberately a separate,
      collapsed section rather than one more toggle beside the routine
      merge/review switches, because these fields decide what a dispatched
      worker may do to this host. The *resolved* posture (what actually
      applies after the base → install → workspace layering in
      `Arbiter.Agents.SecurityPolicy`) is shown above the editor, and any
      submit that would strip a guard — a `safe_defaults` category, the
      sandbox, worktree filesystem scoping, an operator deny rule, or the
      network cut-off — is refused on first submit and re-presented as an
      explicit confirmation naming exactly what is being given up. Only the
      confirm click writes. See `security_downgrades/2`.
    * **Routing detail** (`routing.*`) — beyond the top-level `routing.policy`
      enum: `routing.rules`, a nested map keyed by priority (`P0`..`P4`) or
      difficulty (`D0`..`D4`) tier to a small partial agent-config object
      (`model_tier`/`thinking`/`model`), edited as an add/edit/remove list
      keyed by tier — see `save_routing_rule`/`rm_routing_rule`;
      `routing.base_policy` and `routing.budget_usd_per_day` (`by_budget`
      only); and `routing.adapters`, an ordered list of the same partial
      agent-config shape cycled by `round_robin`.
    * **Standing orders** — add/remove individual orders without clobbering the
      list (`config.standing_orders`).
    * **Secrets** — the *names* of configured secrets only; set/rm via a modal.
      Plaintext values are never echoed back to the page — the form posts a
      value, the server encrypts it, and only the key names return.
    * **Worker env vars** — user-defined env vars injected into every worker's
      subprocess (`Arbiter.Worker.WorkerEnv`). Each may be flagged *secret*,
      which encrypts it and redacts its value from worker logs; secret values
      are masked in the list with an explicit reveal, and the flag can be
      toggled in place without re-entering the value.

  All writes go through Ash actions directly (same VM as the API controller),
  so the server-side `ValidateConfig` guardrails apply identically.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Agents
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig
  alias Arbiter.Tasks.Workspace.Changes.ValidateConfig

  # The model tiers (`agent.config.tier_models`) and thinking levels
  # (`agent.config.thinking_argv`) every adapter defines. They are only the
  # *baseline* row set: operators routinely add keys of their own (real
  # workspaces carry `tier_models.flagship` and `thinking_argv.xhigh`, neither
  # of which appears anywhere in this codebase), so the rendered rows are the
  # baseline unioned with whatever the workspace actually stores — see
  # `model_tiers/1` / `thinking_levels/1`. Hiding an unknown key would leave
  # config only `arb config set` can reach.
  @base_model_tiers ~w[economy standard premium]
  @base_thinking_levels ~w[low medium high]

  # `thinking_argv["none"]` is inert: every adapter's `thinking_argv/1` returns
  # `[]` for "none" before it ever consults the overrides. No row, and the key
  # is left untouched rather than being unset by a blank field.
  @inert_thinking_levels ~w[none]

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
         |> assign(:routing_rule_error, nil)
         |> assign(:worker_env_modal, false)
         |> assign(:worker_env_error, nil)
         |> assign(:revealed_worker_env, MapSet.new())
         |> assign(:config_error, nil)
         |> assign(:order_error, nil)
         |> assign(:details_error, nil)
         |> assign(:agent_config_error, nil)
         |> assign(:security_error, nil)
         |> assign(:security_confirm, nil)
         |> assign(:tracker_types, Workspace.valid_tracker_types())
         |> assign(:merger_strategies, Workspace.valid_merger_strategies())
         |> assign(:agent_types, Agents.valid_agent_types())
         |> assign(:routing_policies, Routing.valid_policies())
         |> assign(:review_automation_modes, ValidateConfig.valid_review_automation_modes())
         |> assign(:security_modes, SecurityPolicy.valid_modes())
         |> assign(:security_filesystems, SecurityPolicy.valid_filesystems())
         |> assign(:safe_default_categories, SecurityPolicy.safe_default_categories())
         |> load_derived()}

      _ ->
        {:ok, assign(socket, workspace: nil, not_found: true)}
    end
  end

  # ---- workspace details (name/prefix) ----

  def handle_event("save_details", %{"details" => %{"name" => name, "prefix" => prefix}}, socket) do
    case Ash.update(socket.assigns.workspace, %{name: name, prefix: prefix}, action: :update) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workspace, ws)
         |> assign(:details_error, nil)
         |> put_flash(:info, "Workspace details saved.")}

      {:error, err} ->
        {:noreply, assign(socket, :details_error, error_message(err))}
    end
  end

  # ---- config form (enums) ----

  @impl true
  def handle_event("save_config", %{"config" => params}, socket) do
    {merge_patch, merge_unset} = merge_settings_patch(params)
    {review_gate_patch, review_gate_unset} = review_gate_settings_patch(params)
    {review_automation_patch, review_automation_unset} = review_automation_settings_patch(params)

    case routing_settings_patch(params) do
      {:ok, {routing_patch, routing_unset}} ->
        patch =
          %{
            "tracker" => %{"type" => params["tracker_type"]},
            "merge" => Map.put(merge_patch, "strategy", params["merger_strategy"]),
            "routing" => Map.put(routing_patch, "policy", params["routing_policy"]),
            "review" => %{"required" => params["review_required"] == "true"}
          }
          |> maybe_put_map("review_gate", review_gate_patch)
          |> maybe_put_map("review_automation", review_automation_patch)

        unset = merge_unset ++ review_gate_unset ++ review_automation_unset ++ routing_unset

        case patch_config(socket.assigns.workspace, patch, unset) do
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

      {:error, msg} ->
        {:noreply, assign(socket, :config_error, msg)}
    end
  end

  # ---- agent-type precedence list (agent.type / review_agent.type) ----

  def handle_event("add_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, fn list ->
      if type in list, do: list, else: list ++ [type]
    end)
  end

  def handle_event("remove_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, &List.delete(&1, type))
  end

  def handle_event("move_agent_type", %{"role" => role, "type" => type, "dir" => dir}, socket) do
    update_agent_types(socket, role, &move_type(&1, type, dir))
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

  # ---- routing.rules (P0..P4 / D0..D4 -> partial agent-config map) ----

  def handle_event("save_routing_rule", %{"rule" => params}, socket) do
    key = params["key"] |> to_string() |> String.trim()

    if key == "" do
      {:noreply, assign(socket, :routing_rule_error, "Rule key can't be empty.")}
    else
      rule = routing_entry_fields(params)
      patch = maybe_put_map(%{}, "routing", maybe_put_map(%{}, "rules", %{key => rule}))

      case patch_config(socket.assigns.workspace, patch, ["routing.rules.#{key}"]) do
        {:ok, ws} ->
          {:noreply,
           socket
           |> assign(:workspace, ws)
           |> assign(:routing_rule_error, nil)
           |> load_derived()}

        {:error, msg} ->
          {:noreply, assign(socket, :routing_rule_error, msg)}
      end
    end
  end

  def handle_event("rm_routing_rule", %{"key" => key}, socket) do
    case patch_config(socket.assigns.workspace, %{}, ["routing.rules.#{key}"]) do
      {:ok, ws} ->
        {:noreply, socket |> assign(:workspace, ws) |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :routing_rule_error, msg)}
    end
  end

  # ---- routing.adapters (ordered list of partial agent-config maps) ----

  def handle_event("add_routing_adapter", %{"adapter" => params}, socket) do
    entry = routing_entry_fields(params)

    if entry == %{} do
      {:noreply, assign(socket, :routing_rule_error, "Adapter entry can't be empty.")}
    else
      adapters = routing_adapters_raw(socket.assigns.workspace) ++ [entry]

      case patch_config(socket.assigns.workspace, %{"routing" => %{"adapters" => adapters}}, []) do
        {:ok, ws} ->
          {:noreply,
           socket
           |> assign(:workspace, ws)
           |> assign(:routing_rule_error, nil)
           |> load_derived()}

        {:error, msg} ->
          {:noreply, assign(socket, :routing_rule_error, msg)}
      end
    end
  end

  def handle_event("rm_routing_adapter", %{"index" => index}, socket) do
    adapters =
      socket.assigns.workspace
      |> routing_adapters_raw()
      |> List.delete_at(String.to_integer(index))

    case patch_config(socket.assigns.workspace, %{"routing" => %{"adapters" => adapters}}, []) do
      {:ok, ws} ->
        {:noreply, socket |> assign(:workspace, ws) |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :routing_rule_error, msg)}
    end
  end

  # ---- review_automation.repo_overrides ----

  def handle_event(
        "add_repo_override",
        %{"repo_override" => %{"repo" => repo, "mode" => mode}},
        socket
      ) do
    repo = String.trim(repo || "")

    if repo == "" do
      {:noreply, assign(socket, :config_error, "Repo override name can't be empty.")}
    else
      case patch_config(
             socket.assigns.workspace,
             %{"review_automation" => %{"repo_overrides" => %{repo => mode}}},
             []
           ) do
        {:ok, ws} ->
          {:noreply,
           socket
           |> assign(:workspace, ws)
           |> assign(:config_error, nil)
           |> load_derived()}

        {:error, msg} ->
          {:noreply, assign(socket, :config_error, msg)}
      end
    end
  end

  def handle_event("rm_repo_override", %{"repo" => repo}, socket) do
    overrides = socket.assigns.workspace |> repo_overrides() |> Map.delete(repo)

    case patch_config(
           socket.assigns.workspace,
           %{"review_automation" => %{"repo_overrides" => overrides}},
           ["review_automation.repo_overrides"]
         ) do
      {:ok, ws} ->
        {:noreply,
         socket |> assign(:workspace, ws) |> assign(:config_error, nil) |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :config_error, msg)}
    end
  end

  # ---- agent.config.* (model / tier_models / thinking_argv / credentials) ----

  def handle_event("save_agent_config", %{"agent_config" => params}, socket) do
    {patch, unset} =
      agent_config_patch(params, socket.assigns.model_tiers, socket.assigns.thinking_levels)

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(:workspace, ws)
         |> assign(:agent_config_error, nil)
         |> load_derived()
         |> put_flash(:info, "Agent config saved.")}

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
        patch = %{
          "agent" => %{
            "config" => %{provider => %{"tier_models" => %{tier => model}}}
          }
        }

        case patch_config(socket.assigns.workspace, patch, []) do
          {:ok, ws} ->
            {:noreply,
             socket
             |> assign(:workspace, ws)
             |> assign(:agent_config_error, nil)
             |> load_derived()}

          {:error, msg} ->
            {:noreply, assign(socket, :agent_config_error, msg)}
        end
    end
  end

  def handle_event("rm_provider_override", %{"provider" => provider, "tier" => tier}, socket) do
    ws = socket.assigns.workspace

    remaining =
      ws
      |> cfg(["agent", "config", provider, "tier_models"], %{})
      |> then(fn m -> if is_map(m), do: m, else: %{} end)
      |> Map.delete(tier)

    # Deep-merge can't delete a map key, so the whole sub-map is unset first
    # and the survivors merged back. `provider` comes from the fixed
    # `Agents.valid_agent_types/0` list, so the dotted path can't be widened
    # by a name containing "." (cf. the review_automation.repo_overrides fix).
    patch = %{"agent" => %{"config" => %{provider => %{"tier_models" => remaining}}}}

    if provider in socket.assigns.agent_types do
      case patch_config(ws, patch, ["agent.config.#{provider}.tier_models"]) do
        {:ok, ws} ->
          {:noreply,
           socket |> assign(:workspace, ws) |> assign(:agent_config_error, nil) |> load_derived()}

        {:error, msg} ->
          {:noreply, assign(socket, :agent_config_error, msg)}
      end
    else
      {:noreply, assign(socket, :agent_config_error, "Unknown provider #{inspect(provider)}.")}
    end
  end

  # ---- agent.security.* (guard-gated) ----

  def handle_event("save_security", %{"security" => params}, socket) do
    ws = socket.assigns.workspace

    case validate_security_params(params) do
      {:error, msg} ->
        {:noreply, socket |> assign(:security_error, msg) |> assign(:security_confirm, nil)}

      :ok ->
        block = security_block(params, socket.assigns.safe_default_categories)

        current = SecurityPolicy.resolve(ws)
        proposed = SecurityPolicy.resolve(%{config: security_preview_config(ws, block)})

        case security_downgrades(current, proposed) do
          [] ->
            {:noreply, apply_security(socket, block)}

          downgrades ->
            # Refuse the plain save: the operator has to look at the list of
            # guards they are giving up and click through, mirroring how
            # destructive operations elsewhere are gated behind an explicit
            # acknowledgement rather than a single submit.
            {:noreply,
             socket
             |> assign(:security_error, nil)
             |> assign(:security_confirm, %{
               block: block,
               downgrades: downgrades,
               posture: SecurityPolicy.one_line(proposed)
             })}
        end
    end
  end

  def handle_event("confirm_security", _params, socket) do
    case socket.assigns.security_confirm do
      %{block: block} -> {:noreply, apply_security(socket, block)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_security", _params, socket) do
    {:noreply, assign(socket, security_confirm: nil, security_error: nil)}
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

  # ---- worker env vars ----

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
             |> assign(:workspace, ws)
             |> assign(worker_env_modal: false, worker_env_error: nil)
             |> load_derived()
             |> put_flash(:info, "Worker env var #{key} saved.")}

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
         |> assign(:workspace, ws)
         |> update(:revealed_worker_env, &MapSet.delete(&1, key))
         |> load_derived()
         |> put_flash(:info, "Worker env var #{key} removed.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # The key can be gone by the time the click lands (removed in another tab, or
  # by another operator), so match it explicitly rather than coercing a missing
  # key into a flag — a stale click is a no-op, not a crash.
  def handle_event("toggle_worker_env_secret", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.worker_env_keys, &(&1.name == key)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Worker env var #{key} no longer exists.")}

      %{secret?: secret?} ->
        toggle_worker_env_secret(socket, key, not secret?)
    end
  end

  def handle_event("reveal_worker_env", %{"key" => key}, socket) do
    {:noreply, update(socket, :revealed_worker_env, &MapSet.put(&1, key))}
  end

  def handle_event("hide_worker_env", %{"key" => key}, socket) do
    {:noreply, update(socket, :revealed_worker_env, &MapSet.delete(&1, key))}
  end

  # ---- Ash write helpers ----

  defp toggle_worker_env_secret(socket, key, new_flag) do
    case set_worker_env(socket.assigns.workspace, %{key => %{"secret" => new_flag}}) do
      {:ok, ws} ->
        {:noreply,
         socket
         # Re-hide the value whenever it flips to secret.
         |> update(:revealed_worker_env, &if(new_flag, do: MapSet.delete(&1, key), else: &1))
         |> assign(:workspace, ws)
         |> load_derived()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # Reorders/adds/removes a provider from the `agent.type` or
  # `review_agent.type` precedence list and persists it via `:patch_config`.
  # Same collapse rule as the old checkbox path (`type_value/2`): a single
  # provider saves as a scalar, an empty worker-agent list falls back to
  # "claude", an empty review-agent list unsets the key (falls back to the
  # worker agent's type).
  defp update_agent_types(socket, role, fun) do
    ws = socket.assigns.workspace
    new_list = ws |> agent_type_list(role) |> fun.() |> Enum.uniq()
    default = if role == "agent", do: "claude", else: nil

    {patch, unset_paths} =
      case type_value(new_list, default) do
        nil -> {%{}, ["#{role}.type"]}
        value -> {%{role => %{"type" => value}}, []}
      end

    case patch_config(ws, patch, unset_paths) do
      {:ok, updated} ->
        {:noreply,
         socket |> assign(:workspace, updated) |> assign(:config_error, nil) |> load_derived()}

      {:error, msg} ->
        {:noreply, assign(socket, :config_error, msg)}
    end
  end

  defp move_type(list, type, "up") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      0 -> list
      idx -> swap(list, idx, idx - 1)
    end
  end

  defp move_type(list, type, "down") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      idx when idx == length(list) - 1 -> list
      idx -> swap(list, idx, idx + 1)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  # Builds the `merge.*` patch/unset pair for `save_config`: booleans always
  # write an explicit true/false (matching `review_required`'s pattern, since
  # false is itself the documented default), while the optional string
  # fields (`pr_title_format`, `watchdog_max_polls`) unset rather than write
  # a blank string when cleared, so the mode-specific server default applies.
  defp merge_settings_patch(params) do
    patch = %{
      "auto_merge" => params["merge_auto_merge"] == "true",
      "watch_pipeline" => params["merge_watch_pipeline"] == "true",
      "auto_sync_primary" => params["merge_auto_sync_primary"] == "true"
    }

    {patch, unset} =
      case blank_to_nil(params["merge_pr_title_format"]) do
        nil -> {patch, ["merge.pr_title_format"]}
        v -> {Map.put(patch, "pr_title_format", v), []}
      end

    case blank_to_nil(params["merge_watchdog_max_polls"]) do
      nil -> {patch, unset ++ ["merge.watchdog_max_polls"]}
      v -> {Map.put(patch, "watchdog_max_polls", v), unset}
    end
  end

  # Builds the `routing.base_policy`/`budget_usd_per_day` patch/unset pair
  # (siblings `policy`/`rules`/`adapters` are managed separately so they
  # survive this form's submit untouched). `budget_usd_per_day` is parsed to
  # a number here — `ByBudget.over_budget?/2` compares it against the
  # ledger's `cost_usd_today` with `is_number/1` and silently no-ops
  # otherwise, so a stored string would make the budget gate inert.
  defp routing_settings_patch(params) do
    {patch, unset} =
      case blank_to_nil(params["routing_base_policy"]) do
        nil -> {%{}, ["routing.base_policy"]}
        v -> {%{"base_policy" => v}, []}
      end

    case blank_to_nil(params["routing_budget_usd_per_day"]) do
      nil ->
        {:ok, {patch, unset ++ ["routing.budget_usd_per_day"]}}

      v ->
        case Float.parse(v) do
          {num, ""} -> {:ok, {Map.put(patch, "budget_usd_per_day", num), unset}}
          _ -> {:error, "Daily budget (routing.budget_usd_per_day) must be a number."}
        end
    end
  end

  # A single `routing.rules[tier]` / `routing.adapters[]` entry — the
  # provider-agnostic `model_tier`/`thinking` abstraction `ByDifficulty` and
  # `RoundRobin` know about, plus a raw `model` escape hatch for power users
  # bypassing the abstraction (same precedent as `ByPriority`'s example).
  # Blank fields are omitted rather than written empty.
  defp routing_entry_fields(params) do
    %{}
    |> maybe_put_entry_field(params, "model_tier")
    |> maybe_put_entry_field(params, "thinking")
    |> maybe_put_entry_field(params, "model")
  end

  defp maybe_put_entry_field(map, params, key) do
    case blank_to_nil(params[key]) do
      nil -> map
      v -> Map.put(map, key, v)
    end
  end

  # Builds the `review_gate.*` patch/unset pair: both fields are optional
  # positive integers with a difficulty-derived server default, so a blank
  # field unsets rather than writing an empty string (same pattern as
  # `merge.pr_title_format`/`merge.watchdog_max_polls`).
  defp review_gate_settings_patch(params) do
    {patch, unset} =
      case blank_to_nil(params["review_gate_max_rounds"]) do
        nil -> {%{}, ["review_gate.max_rounds"]}
        v -> {%{"max_rounds" => v}, []}
      end

    case blank_to_nil(params["review_gate_timeout_ms"]) do
      nil -> {patch, unset ++ ["review_gate.timeout_ms"]}
      v -> {Map.put(patch, "timeout_ms", v), unset}
    end
  end

  # Builds the `review_automation.default`/`auto_authors` patch/unset pair
  # (siblings `repo_overrides` are managed separately via add/rm_repo_override
  # so they don't get clobbered by this form's submit). `auto_authors` is
  # entered as a comma-separated string and split into a list, dropping blank
  # entries.
  defp review_automation_settings_patch(params) do
    {patch, unset} =
      case blank_to_nil(params["review_automation_default"]) do
        nil -> {%{}, ["review_automation.default"]}
        v -> {%{"default" => v}, []}
      end

    case blank_to_nil(params["review_automation_auto_authors"]) do
      nil ->
        {patch, unset ++ ["review_automation.auto_authors"]}

      v ->
        authors = v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        {Map.put(patch, "auto_authors", authors), unset}
    end
  end

  # Builds the `agent.config.*` patch/unset pair. Every field here is an
  # *override* of an adapter default, so a blank field unsets rather than
  # writing "" (which the adapters would happily use as a model name). Keys
  # this form doesn't own — `vernacular`, `api_keys`, the routing rules — are
  # siblings under `agent.config` and survive the deep merge untouched.
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

  # `mode` and `sandbox.filesystem` are the two enum fields the form writes
  # verbatim into config, and `ValidateConfig` has no `agent.security` branch
  # to catch a bad one. An unrecognized value is not inert: `SecurityPolicy`
  # reads config leniently, so `parse_mode/2` would silently fall back to the
  # *base* default (`:bypass`) — a workspace pinned at `:strict` would be
  # quietly downgraded while `arb config get agent.security` still showed the
  # junk string. Reject it instead, the way `add_provider_override` checks its
  # provider/tier against fixed lists.
  defp validate_security_params(params) do
    mode = params["mode"]
    filesystem = params["sandbox_filesystem"]
    valid_modes = Enum.map(SecurityPolicy.valid_modes(), &Atom.to_string/1)
    valid_filesystems = Enum.map(SecurityPolicy.valid_filesystems(), &Atom.to_string/1)

    cond do
      mode not in valid_modes ->
        {:error,
         "Unknown permission mode #{inspect(mode)} — expected one of #{Enum.join(valid_modes, ", ")}."}

      filesystem not in valid_filesystems ->
        {:error,
         "Unknown filesystem scope #{inspect(filesystem)} — expected one of #{Enum.join(valid_filesystems, ", ")}."}

      true ->
        :ok
    end
  end

  # Normalizes the security form params into an `agent.security` config block.
  # Written whole (rather than field-by-field) so the resolved posture the
  # operator confirmed is exactly what lands. `mode` / `sandbox_filesystem`
  # are pre-validated by `validate_security_params/1`.
  defp security_block(params, categories) do
    safe_defaults = params["safe_defaults"] || %{}

    %{
      "permissions" => %{
        "mode" => params["mode"],
        "allow" => rule_list(params["allow"]),
        "deny" => rule_list(params["deny"]),
        "safe_defaults" =>
          categories
          |> Enum.map(&Atom.to_string/1)
          |> Enum.filter(&(Map.get(safe_defaults, &1) == "true"))
      },
      "sandbox" => %{
        "enabled" => params["sandbox_enabled"] == "true",
        "filesystem" => params["sandbox_filesystem"],
        "network" => params["sandbox_network"] == "true"
      }
    }
  end

  # The config the workspace *would* have, used to resolve the proposed
  # posture through the same layering as the live one — so the confirmation
  # compares effective postures, not raw config fragments.
  defp security_preview_config(ws, block) do
    PatchConfig.deep_merge(ws.config || %{}, %{"agent" => %{"security" => block}})
  end

  # Every way the proposed posture gives up ground relative to the current
  # one, as operator-readable strings. Tightenings (stricter mode, network
  # cut, added deny rules) are deliberately absent — they need no gate.
  #
  # `mode` counts: the deny list is a hard block in every mode
  # (`Claude.Security.settings_argv/1` is emitted even for `:bypass`), but
  # that is not the whole guard. `:strict` maps to `--permission-mode default`
  # / `"defaultMode" => "default"`, under which only allow-listed tools run;
  # `:auto` keeps the interactive classifier; `:bypass`
  # (`--dangerously-skip-permissions`) drops both, so anything not explicitly
  # denied runs. Loosening the mode is therefore the widest-blast-radius
  # control on this form and gets the same confirm step as the rest.
  @mode_strictness %{strict: 2, auto: 1, bypass: 0}

  defp security_downgrades(current, proposed) do
    mode =
      if mode_rank(proposed.permissions.mode) < mode_rank(current.permissions.mode) do
        [
          "Loosens the permission mode (#{current.permissions.mode} → #{proposed.permissions.mode}) — " <>
            mode_loss(proposed.permissions.mode)
        ]
      else
        []
      end

    removed_guards =
      Enum.map(
        current.permissions.safe_defaults -- proposed.permissions.safe_defaults,
        &"Removes the #{&1} safe-default guard"
      )

    removed_denies =
      Enum.map(
        current.permissions.deny -- proposed.permissions.deny,
        &"Removes the deny rule #{&1}"
      )

    sandbox =
      [
        {current.sandbox.enabled and not proposed.sandbox.enabled,
         "Disables the sandbox entirely (sandbox.enabled true → false)"},
        {current.sandbox.filesystem == :worktree and proposed.sandbox.filesystem != :worktree,
         "Widens filesystem access beyond the worktree (sandbox.filesystem worktree → #{proposed.sandbox.filesystem})"},
        {not current.sandbox.network and proposed.sandbox.network,
         "Restores worker network egress (sandbox.network false → true)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    mode ++ removed_guards ++ sandbox ++ removed_denies
  end

  defp mode_rank(mode), do: Map.get(@mode_strictness, mode, 0)

  defp mode_loss(:bypass),
    do: "tools are no longer restricted to the allow list and the classifier is skipped"

  defp mode_loss(:auto), do: "tools are no longer restricted to the allow list"
  defp mode_loss(mode), do: "the #{mode} mode is looser"

  defp apply_security(socket, block) do
    case patch_config(socket.assigns.workspace, %{"agent" => %{"security" => block}}, []) do
      {:ok, ws} ->
        socket
        |> assign(:workspace, ws)
        |> assign(:security_error, nil)
        |> assign(:security_confirm, nil)
        |> load_derived()
        |> put_flash(:info, "Security posture saved.")

      {:error, msg} ->
        socket |> assign(:security_error, msg) |> assign(:security_confirm, nil)
    end
  end

  # allow/deny rules are entered one per line; blanks are dropped so a
  # trailing newline doesn't become an empty rule.
  defp rule_list(nil), do: []

  defp rule_list(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp rule_list(_), do: []

  defp maybe_put_map(patch, _key, empty) when empty == %{}, do: patch
  defp maybe_put_map(patch, key, value), do: Map.put(patch, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

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

  defp set_worker_env(ws, patch) do
    case Ash.update(ws, %{worker_env: patch}, action: :update) do
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
    |> assign(:worker_env_keys, Workspace.worker_env_keys(ws))
    |> assign(:worker_env_values, Workspace.worker_env_map(ws))
    |> assign(:orders, standing_orders(ws))
    |> assign(:routing_rules, routing_rules(ws))
    |> assign(:routing_adapters, routing_adapters(ws))
    |> assign(:repo_overrides, repo_overrides(ws) |> Enum.sort())
    |> assign(:provider_overrides, provider_overrides(ws))
    |> assign(:model_tiers, model_tiers(ws))
    |> assign(:thinking_levels, thinking_levels(ws))
    |> assign(:security_policy, SecurityPolicy.resolve(ws))
    |> assign(:security_repo_postures, security_repo_postures(ws))
  end

  # `agent.security.repos.<repo>` is a whole extra layer applied on top of the
  # workspace-wide posture for dispatches against that repo, so the resolved
  # workspace line alone can misrepresent what a worker actually gets (a repo
  # can, say, turn the sandbox back off). Resolved through the same
  # `SecurityPolicy.resolve/3` path and listed read-only under the posture
  # panel; this form edits the workspace layer only, that one stays CLI-owned.
  defp security_repo_postures(ws) do
    case cfg(ws, ["agent", "security", "repos"]) do
      %{} = repos ->
        repos
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.sort()
        |> Enum.map(&{&1, SecurityPolicy.resolve(ws, %{}, &1)})

      _ ->
        []
    end
  end

  # The baseline keys plus every key this workspace actually stores (including
  # per-provider sub-maps, so a tier only Codex overrides still gets a row in
  # the add-override picker). Baseline order first, extras alphabetical.
  defp model_tiers(ws) do
    stored =
      [config_map(ws, ["agent", "config", "tier_models"])]
      |> Enum.concat(Enum.map(Agents.valid_agent_types(), &provider_tier_models(ws, &1)))
      |> Enum.flat_map(&Map.keys/1)

    order_keys(@base_model_tiers, stored)
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

  # A nested config map, or `%{}` for anything that isn't one — `agent.config`
  # is free-form JSON, so a scalar at any level is possible and must not crash
  # the page.
  defp config_map(ws, path) do
    Enum.reduce(path, ws.config || %{}, fn key, acc ->
      case acc do
        %{} = map -> Map.get(map, key, %{})
        _ -> %{}
      end
    end)
    |> case do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp standing_orders(ws) do
    case get_in(ws.config || %{}, ["standing_orders"]) do
      list when is_list(list) -> list
      _ -> []
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

  defp routing_adapters_raw(ws) do
    case cfg(ws, ["routing", "adapters"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp routing_adapters(ws), do: ws |> routing_adapters_raw() |> Enum.with_index()

  defp routing_entry_summary(entry) when is_map(entry) and map_size(entry) > 0 do
    entry |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp routing_entry_summary(_entry), do: "(empty)"

  defp cfg(ws, path, default \\ nil) do
    case get_in(ws.config || %{}, path) do
      nil -> default
      v -> v
    end
  end

  # `agent.type` / `review_agent.type` may be a scalar string or a
  # multi-provider pool list. Normalize to a list of checked provider names
  # for the checkbox group.
  defp agent_type_list(ws, role) do
    case cfg(ws, [role, "type"]) do
      t when is_binary(t) -> [t]
      types when is_list(types) -> types
      _ -> []
    end
  end

  # Collapse a checkbox selection back to the config shape: a single
  # provider saves as a scalar string (matching existing single-provider
  # workspaces), multiple providers save as a pool list. An empty selection
  # falls back to `default` (nil signals "unset this key").
  defp type_value([], default), do: default
  defp type_value([single], _default), do: single
  defp type_value(many, _default) when is_list(many), do: many

  defp order_text(order) when is_binary(order), do: order

  defp order_text(%{"title" => title} = order) do
    case order["detail"] do
      d when is_binary(d) and d != "" -> "#{title} — #{d}"
      _ -> title
    end
  end

  defp order_text(order), do: inspect(order)

  defp review_required?(ws), do: cfg(ws, ["review", "required"]) in [true, "true"]

  defp repo_overrides(ws) do
    case cfg(ws, ["review_automation", "repo_overrides"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp auto_authors_text(ws) do
    case cfg(ws, ["review_automation", "auto_authors"]) do
      list when is_list(list) -> Enum.join(list, ", ")
      _ -> ""
    end
  end

  # ---- agent.config.* form prefill ----

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

  # `credentials_ref` is picked from the workspace's own secret registry — the
  # page never offers a box a raw token could be pasted into. A ref set
  # outside the dashboard (typically `env:NAME`) is carried as an extra option
  # so opening this form and saving can't silently drop it.
  defp credentials_ref_options(secret_keys, current) do
    options = [{"(unset)", ""} | Enum.map(secret_keys, &{"secret:#{&1}", "secret:#{&1}"})]

    if current == "" or Enum.any?(options, fn {_label, value} -> value == current end) do
      options
    else
      options ++ [{"#{current} (set outside the dashboard)", current}]
    end
  end

  # ---- agent.security.* form prefill ----

  # The form is seeded from the *resolved* posture, not the raw config block:
  # what the operator sees is what a worker dispatched right now would get,
  # and saving pins exactly that.
  defp rules_text(rules), do: Enum.join(rules, "\n")

  defp security_summary(policy), do: SecurityPolicy.one_line(policy)

  # ---- agent-type precedence list component ----

  # Renders `selected` as an ordered, reorderable list (order = precedence,
  # first-listed wins per `Arbiter.Agents.ProviderPool`) plus buttons to add
  # any remaining `available` provider. All actions patch-save immediately,
  # mirroring the standing-orders add/remove pattern elsewhere on this page.
  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :selected, :list, required: true
  attr :available, :list, required: true
  attr :hint, :string, default: nil

  defp agent_type_editor(assigns) do
    ~H"""
    <fieldset class="fieldset">
      <legend class="fieldset-legend">{@label}</legend>
      <ol class="space-y-1">
        <li
          :for={{type, idx} <- Enum.with_index(@selected)}
          class="flex items-center gap-2 bg-base-100 rounded px-2 py-1 border border-base-300 text-sm"
        >
          <span class="text-xs text-base-content/40 font-mono w-4">{idx + 1}</span>
          <span class="flex-1">{type}</span>
          <button
            type="button"
            phx-click="move_agent_type"
            phx-value-role={@role}
            phx-value-type={type}
            phx-value-dir="up"
            disabled={idx == 0}
            class="btn btn-xs btn-ghost btn-square"
            aria-label={"Move #{type} up"}
          >
            <.icon name="hero-chevron-up" class="size-3" />
          </button>
          <button
            type="button"
            phx-click="move_agent_type"
            phx-value-role={@role}
            phx-value-type={type}
            phx-value-dir="down"
            disabled={idx == length(@selected) - 1}
            class="btn btn-xs btn-ghost btn-square"
            aria-label={"Move #{type} down"}
          >
            <.icon name="hero-chevron-down" class="size-3" />
          </button>
          <button
            type="button"
            phx-click="remove_agent_type"
            phx-value-role={@role}
            phx-value-type={type}
            class="btn btn-xs btn-ghost btn-square text-error"
            aria-label={"Remove #{type}"}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
        <li :if={@selected == []} class="text-xs text-base-content/40 italic">
          None selected.
        </li>
      </ol>
      <div :if={@available != []} class="flex flex-wrap gap-1 mt-1">
        <button
          :for={type <- @available}
          type="button"
          phx-click="add_agent_type"
          phx-value-role={@role}
          phx-value-type={type}
          class="btn btn-xs btn-outline gap-1"
        >
          <.icon name="hero-plus" class="size-3" /> {type}
        </button>
      </div>
      <p :if={@hint} class="text-xs text-base-content/50">{@hint}</p>
    </fieldset>
    """
  end

  # ---- render ----

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
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
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
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

        <%!-- Workspace details (name/prefix) --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold flex items-center gap-2">
              <.icon name="hero-identification" class="size-5 text-base-content/60" />
              Workspace details
            </h2>
            <.form
              for={%{}}
              as={:details}
              phx-submit="save_details"
              class="grid sm:grid-cols-2 gap-x-4"
            >
              <.input
                name="details[name]"
                label="Name"
                value={@workspace.name}
                required
              />
              <div>
                <.input
                  name="details[prefix]"
                  label="Prefix"
                  value={@workspace.prefix}
                  pattern="[a-z][a-z0-9]*"
                  maxlength="16"
                  required
                />
                <p class="text-xs text-base-content/50 mt-1">
                  Changing the prefix does not rename existing issue IDs — the prefix is baked
                  into each ID at creation time, so old and new issues will show different
                  prefixes in this workspace. This is expected.
                </p>
              </div>
              <div class="sm:col-span-2 flex items-center gap-3 mt-2">
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Save details
                </.button>
                <p :if={@details_error} class="text-sm text-error">{@details_error}</p>
              </div>
            </.form>
          </div>
        </section>

        <%!-- Configuration --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" /> Configuration
            </h2>
            <div class="grid sm:grid-cols-2 gap-x-4 gap-y-3">
              <.agent_type_editor
                role="agent"
                label="Worker agent (agent.type)"
                selected={agent_type_list(@workspace, "agent")}
                available={@agent_types -- agent_type_list(@workspace, "agent")}
              />
              <.agent_type_editor
                role="review_agent"
                label="Review agent (review_agent.type)"
                selected={agent_type_list(@workspace, "review_agent")}
                available={@agent_types -- agent_type_list(@workspace, "review_agent")}
                hint="Leave empty to fall back to the worker agent's type."
              />
            </div>
            <.form
              for={%{}}
              as={:config}
              phx-submit="save_config"
              class="grid sm:grid-cols-2 gap-x-4"
            >
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
              <.input
                type="select"
                name="config[routing_base_policy]"
                label="Budget base policy (routing.base_policy, by_budget only)"
                options={[
                  {"(unset — defaults to by_priority)", ""},
                  {"by_priority", "by_priority"},
                  {"by_difficulty", "by_difficulty"}
                ]}
                value={cfg(@workspace, ["routing", "base_policy"], "")}
              />
              <.input
                type="text"
                name="config[routing_budget_usd_per_day]"
                label="Daily budget USD (routing.budget_usd_per_day, by_budget only)"
                placeholder="e.g. 25"
                value={cfg(@workspace, ["routing", "budget_usd_per_day"], "")}
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
              <.input
                type="text"
                name="config[review_gate_max_rounds]"
                label="ReviewGate max rounds (review_gate.max_rounds)"
                placeholder="default: varies by difficulty"
                value={cfg(@workspace, ["review_gate", "max_rounds"], "")}
              />
              <.input
                type="text"
                name="config[review_gate_timeout_ms]"
                label="ReviewGate per-round timeout ms (review_gate.timeout_ms)"
                placeholder="default: 1200000"
                value={cfg(@workspace, ["review_gate", "timeout_ms"], "")}
              />
              <.input
                type="select"
                name="config[review_automation_default]"
                label="Reviewer dispatch mode (review_automation.default)"
                options={[{"(unset)", ""} | Enum.map(@review_automation_modes, &{&1, &1})]}
                value={cfg(@workspace, ["review_automation", "default"], "")}
              />
              <.input
                type="text"
                name="config[review_automation_auto_authors]"
                label="Auto-approve authors (review_automation.auto_authors)"
                placeholder="comma-separated PR authors, e.g. alice, bob"
                value={auto_authors_text(@workspace)}
              />
              <.input
                type="select"
                name="config[merge_pr_title_format]"
                label="PR title format (merge.pr_title_format)"
                options={[{"Raw (default)", ""}, {"Conventional Commit", "conventional_commit"}]}
                value={cfg(@workspace, ["merge", "pr_title_format"], "")}
              />
              <.input
                type="text"
                name="config[merge_watchdog_max_polls]"
                label="Watchdog max polls (merge.watchdog_max_polls)"
                placeholder="default: varies by auto_merge mode"
                value={cfg(@workspace, ["merge", "watchdog_max_polls"], "")}
              />
              <label class="fieldset flex items-center gap-2 mt-6">
                <input type="hidden" name="config[merge_auto_merge]" value="false" />
                <input
                  type="checkbox"
                  name="config[merge_auto_merge]"
                  value="true"
                  checked={Workspace.auto_merge?(@workspace)}
                  class="toggle toggle-sm toggle-primary"
                />
                <span class="text-sm">Auto-merge on review approval (merge.auto_merge)</span>
              </label>
              <label class="fieldset flex items-center gap-2 mt-6">
                <input type="hidden" name="config[merge_watch_pipeline]" value="false" />
                <input
                  type="checkbox"
                  name="config[merge_watch_pipeline]"
                  value="true"
                  checked={Workspace.watch_pipeline?(@workspace)}
                  class="toggle toggle-sm toggle-primary"
                />
                <span class="text-sm">
                  Wait for CI pipeline before merging (merge.watch_pipeline)
                </span>
              </label>
              <label class="fieldset flex items-center gap-2 mt-6">
                <input type="hidden" name="config[merge_auto_sync_primary]" value="false" />
                <input
                  type="checkbox"
                  name="config[merge_auto_sync_primary]"
                  value="true"
                  checked={Workspace.auto_sync_primary?(@workspace)}
                  class="toggle toggle-sm toggle-primary"
                />
                <span class="text-sm">
                  Fast-forward primary checkout after merge (merge.auto_sync_primary)
                </span>
              </label>
              <div class="sm:col-span-2 flex items-center gap-3 mt-2">
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Save configuration
                </.button>
                <p :if={@config_error} class="text-sm text-error">{@config_error}</p>
              </div>
            </.form>
            <p class="text-xs text-base-content/50">
              Adapter-specific tracker/merger details (hosts, owner/repo) are still set with <code>arb config set</code>. Worker security lives in its own section below.
            </p>

            <div class="border-t border-base-300 pt-3">
              <h3 class="font-semibold text-sm flex items-center gap-2">
                Per-repo dispatch overrides
                <span class="text-base-content/40 font-normal">({length(@repo_overrides)})</span>
              </h3>
              <p class="text-xs text-base-content/50 mt-1">
                <code>review_automation.repo_overrides</code> — overrides the dispatch mode above for
                a specific repo.
              </p>

              <ul :if={@repo_overrides != []} id="repo-overrides" class="flex flex-col gap-1.5 mt-2">
                <li
                  :for={{repo, mode} <- @repo_overrides}
                  class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-2"
                >
                  <code class="text-sm flex-1">{repo}</code>
                  <span class="badge badge-sm badge-ghost font-mono">{mode}</span>
                  <button
                    type="button"
                    phx-click="rm_repo_override"
                    phx-value-repo={repo}
                    class="btn btn-ghost btn-xs text-error shrink-0"
                    aria-label={"Remove override for #{repo}"}
                    data-confirm={"Remove the review_automation override for #{repo}?"}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </li>
              </ul>

              <.form
                for={%{}}
                as={:repo_override}
                phx-submit="add_repo_override"
                class="flex gap-2 items-start mt-2"
              >
                <input
                  type="text"
                  name="repo_override[repo]"
                  placeholder="owner/repo"
                  class="input input-sm flex-1"
                  required
                />
                <select name="repo_override[mode]" class="select select-sm">
                  <option :for={mode <- @review_automation_modes} value={mode}>{mode}</option>
                </select>
                <.button type="submit" class="btn btn-sm">
                  <.icon name="hero-plus" class="size-4" /> Add
                </.button>
              </.form>
            </div>

            <div class="border-t border-base-300 pt-3">
              <h3 class="font-semibold text-sm flex items-center gap-2">
                Routing rules
                <span class="text-base-content/40 font-normal">({length(@routing_rules)})</span>
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

            <div class="border-t border-base-300 pt-3">
              <h3 class="font-semibold text-sm flex items-center gap-2">
                Round-robin adapters
                <span class="text-base-content/40 font-normal">({length(@routing_adapters)})</span>
              </h3>
              <p class="text-xs text-base-content/50 mt-1">
                <code>routing.adapters</code>
                — ordered list of agent-config overrides cycled per dispatch (<code>round_robin</code> policy only).
              </p>

              <ul
                :if={@routing_adapters != []}
                id="routing-adapters"
                class="flex flex-col gap-1.5 mt-2"
              >
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
            </div>
          </div>
        </section>

        <%!-- Agent model config (agent.config.*) --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
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
                options={
                  credentials_ref_options(@secret_keys, agent_cfg(@workspace, "credentials_ref"))
                }
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

        <%!-- Advanced / security (agent.security.*) — deliberately separated
             from the routine toggles above: these fields decide what a worker
             may do to this host. --%>
        <section
          id="agent-security"
          class="card bg-base-200 border-2 border-warning/40 shadow-sm"
        >
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
              Advanced — worker security
            </h2>
            <p class="text-xs text-base-content/50 -mt-1">
              <code>agent.security.*</code>
              controls the filesystem, network and destructive-action guardrails applied to every
              worker this workspace dispatches on this machine. Weakening a guard needs an explicit
              confirmation.
            </p>

            <div class="rounded-box border border-base-300 bg-base-100 px-3 py-2">
              <p class="text-xs uppercase tracking-wide text-base-content/50">
                Effective workspace-wide posture right now
              </p>
              <p class="font-mono text-sm mt-0.5">{security_summary(@security_policy)}</p>
              <div class="flex flex-wrap gap-1 mt-2">
                <span class="badge badge-sm badge-outline font-mono">
                  mode={@security_policy.permissions.mode}
                </span>
                <span class={[
                  "badge badge-sm font-mono",
                  if(@security_policy.sandbox.enabled, do: "badge-success", else: "badge-error")
                ]}>
                  sandbox={if @security_policy.sandbox.enabled, do: "on", else: "OFF"}
                </span>
                <span class={[
                  "badge badge-sm font-mono",
                  if(@security_policy.sandbox.filesystem == :worktree,
                    do: "badge-success",
                    else: "badge-error"
                  )
                ]}>
                  fs={@security_policy.sandbox.filesystem}
                </span>
                <span class="badge badge-sm badge-outline font-mono">
                  net={if @security_policy.sandbox.network, do: "on", else: "tools-off"}
                </span>
                <span class={[
                  "badge badge-sm font-mono",
                  if(
                    length(@security_policy.permissions.safe_defaults) ==
                      length(@safe_default_categories),
                    do: "badge-success",
                    else: "badge-warning"
                  )
                ]}>
                  safe_defaults={length(@security_policy.permissions.safe_defaults)}/{length(
                    @safe_default_categories
                  )}
                </span>
              </div>

              <%!-- agent.security.repos.<repo> layers on top of the line above
                   for dispatches against that repo, so the workspace-wide
                   posture is not the whole story. Read-only: the form below
                   edits the workspace layer only. --%>
              <div :if={@security_repo_postures != []} id="security-repo-postures" class="mt-3">
                <p class="text-xs uppercase tracking-wide text-base-content/50">
                  Per-repo overrides (<code>agent.security.repos.*</code>) — applied on top of the
                  line above; edit via <code>arb config</code>
                </p>
                <ul class="mt-1 flex flex-col gap-0.5">
                  <li
                    :for={{repo, policy} <- @security_repo_postures}
                    class="font-mono text-xs flex flex-wrap gap-x-2"
                  >
                    <span class="text-base-content/60">{repo}:</span>
                    <span>{security_summary(policy)}</span>
                  </li>
                </ul>
              </div>
            </div>

            <details class="collapse collapse-arrow border border-base-300 bg-base-100">
              <summary class="collapse-title text-sm font-medium">
                Edit security posture
              </summary>
              <div class="collapse-content">
                <.form for={%{}} as={:security} phx-submit="save_security" class="space-y-3">
                  <div class="grid sm:grid-cols-2 gap-x-4">
                    <.input
                      type="select"
                      name="security[mode]"
                      label="Permission mode (permissions.mode)"
                      options={Enum.map(@security_modes, &{Atom.to_string(&1), Atom.to_string(&1)})}
                      value={Atom.to_string(@security_policy.permissions.mode)}
                    />
                    <.input
                      type="select"
                      name="security[sandbox_filesystem]"
                      label="Filesystem scope (sandbox.filesystem)"
                      options={
                        Enum.map(@security_filesystems, &{Atom.to_string(&1), Atom.to_string(&1)})
                      }
                      value={Atom.to_string(@security_policy.sandbox.filesystem)}
                    />
                    <label class="fieldset flex items-center gap-2 mt-2">
                      <input type="hidden" name="security[sandbox_enabled]" value="false" />
                      <input
                        type="checkbox"
                        name="security[sandbox_enabled]"
                        value="true"
                        checked={@security_policy.sandbox.enabled}
                        class="toggle toggle-sm toggle-primary"
                      />
                      <span class="text-sm">Sandbox enabled (sandbox.enabled)</span>
                    </label>
                    <label class="fieldset flex items-center gap-2 mt-2">
                      <input type="hidden" name="security[sandbox_network]" value="false" />
                      <input
                        type="checkbox"
                        name="security[sandbox_network]"
                        value="true"
                        checked={@security_policy.sandbox.network}
                        class="toggle toggle-sm toggle-primary"
                      />
                      <span class="text-sm">Network egress allowed (sandbox.network)</span>
                    </label>
                  </div>

                  <fieldset class="fieldset">
                    <legend class="label">Safe-default guards (permissions.safe_defaults)</legend>
                    <p class="text-xs text-base-content/50">
                      The baseline destructive-op categories every adapter denies. Unchecking one
                      requires confirmation.
                    </p>
                    <div class="flex flex-wrap gap-x-4 gap-y-1 mt-1">
                      <label
                        :for={category <- @safe_default_categories}
                        class="flex items-center gap-2 text-sm cursor-pointer"
                      >
                        <input
                          type="hidden"
                          name={"security[safe_defaults][#{category}]"}
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name={"security[safe_defaults][#{category}]"}
                          value="true"
                          checked={category in @security_policy.permissions.safe_defaults}
                          class="checkbox checkbox-sm"
                        />
                        <code>{category}</code>
                      </label>
                    </div>
                  </fieldset>

                  <div class="grid sm:grid-cols-2 gap-x-4">
                    <.input
                      type="textarea"
                      name="security[allow]"
                      label="Allow rules (permissions.allow) — one per line"
                      value={rules_text(@security_policy.permissions.allow)}
                      rows="4"
                    />
                    <.input
                      type="textarea"
                      name="security[deny]"
                      label="Deny rules (permissions.deny) — one per line"
                      value={rules_text(@security_policy.permissions.deny)}
                      rows="4"
                    />
                  </div>

                  <div class="flex items-center gap-3">
                    <.button type="submit" class="btn btn-sm btn-warning">
                      Review security changes
                    </.button>
                    <p :if={@security_error} class="text-sm text-error">{@security_error}</p>
                  </div>
                </.form>
              </div>
            </details>
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

        <%!-- Worker env vars --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <div class="flex items-center justify-between gap-2">
              <h2 class="font-semibold flex items-center gap-2">
                <.icon name="hero-variable" class="size-5 text-base-content/60" /> Worker env vars
                <span class="text-base-content/40 font-normal">({length(@worker_env_keys)})</span>
              </h2>
              <.button phx-click="open_worker_env_modal" class="btn btn-sm">
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
                  phx-value-key={entry.name}
                  class="btn btn-ghost btn-xs shrink-0"
                  aria-label="Hide value"
                >
                  <.icon name="hero-eye-slash" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="toggle_worker_env_secret"
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
          </div>
        </section>
      </div>

      <%!-- Security-downgrade confirmation. The plain submit above never
           writes when a guard is being removed; this is the only path that
           applies such a change, and it names each guard explicitly. --%>
      <div :if={@security_confirm} class="modal modal-open" id="security-confirm-modal">
        <div class="modal-box border-2 border-error/50">
          <h3 class="font-semibold text-lg mb-1 flex items-center gap-2">
            <.icon name="hero-shield-exclamation" class="size-5 text-error" />
            Weaken this workspace's security posture?
          </h3>
          <p class="text-sm text-base-content/70">
            These changes remove guardrails from every worker this workspace dispatches on this
            machine:
          </p>
          <ul class="list-disc list-inside text-sm text-error mt-2 space-y-1">
            <li :for={downgrade <- @security_confirm.downgrades}>{downgrade}</li>
          </ul>
          <p class="text-xs text-base-content/50 mt-3">
            Resulting workspace-wide posture:
            <span class="font-mono">{@security_confirm.posture}</span>
          </p>
          <p :if={@security_repo_postures != []} class="text-xs text-warning mt-1">
            {length(@security_repo_postures)} per-repo override(s) still layer on top of this — see
            <code>agent.security.repos.*</code>
            in the posture panel.
          </p>
          <div class="modal-action">
            <.button type="button" phx-click="cancel_security" class="btn btn-sm btn-ghost">
              Cancel
            </.button>
            <.button type="button" phx-click="confirm_security" class="btn btn-sm btn-error">
              I understand — weaken the posture
            </.button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="cancel_security"></div>
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

      <%!-- Set-worker-env modal --%>
      <div :if={@worker_env_modal} class="modal modal-open" id="worker-env-modal">
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-3">Set worker env var</h3>
          <.form for={%{}} as={:worker_env} phx-submit="set_worker_env" class="space-y-2">
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
              <.button type="button" phx-click="close_worker_env_modal" class="btn btn-sm btn-ghost">
                Cancel
              </.button>
              <.button type="submit" variant="primary" class="btn btn-sm btn-primary">Save</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close_worker_env_modal"></div>
      </div>
    </Layouts.app>
    """
  end

  # Value shown for a worker env var row: a secret value stays masked until the
  # operator explicitly reveals it; plain values are shown inline.
  defp worker_env_display(%{name: name, secret?: true}, values, revealed) do
    if MapSet.member?(revealed, name), do: Map.get(values, name, ""), else: "••••••••"
  end

  defp worker_env_display(%{name: name}, values, _revealed), do: Map.get(values, name, "")
end
