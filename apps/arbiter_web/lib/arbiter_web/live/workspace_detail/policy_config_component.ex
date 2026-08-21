defmodule ArbiterWeb.WorkspaceDetail.PolicyConfigComponent do
  @moduledoc """
  The workspace's dispatch policy: which agent types run (and in what
  precedence order), which tracker/merger back the workspace, and the
  `merge.*` / `review*` / `routing.*` / `quota.*` / `conductor.*` /
  `pr_patrol.*` knobs that shape every dispatch.

  One form, one submit: these fields are read together at dispatch time, so
  saving them together keeps the workspace from sitting in a half-applied
  state. Each `*_settings_patch/1` builder returns a `{patch, unset_paths}`
  pair — blank optional fields *unset* their key rather than writing `""`,
  so the server-side default applies again instead of an empty string
  becoming the configured value. Keys this form does not own (the routing
  rules/adapters, the repo overrides, `agent.config.*`) are siblings under
  the same config subtrees and survive the deep merge untouched, which is
  why they live in their own sibling components.

  The agent-type precedence editors write immediately (each click is its own
  `patch_config`) rather than participating in the submit, matching the
  add/remove-row behavior of the other list editors on this page.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Tasks.Workspace

  @impl true
  def mount(socket), do: {:ok, assign(socket, :config_error, nil)}

  # The tracker type is picked here but decides which adapter-specific fields
  # the tracker section shows, so this component owns the preview and renders
  # that section as a child: a `phx-change` on the select has to reveal the
  # right fields in the *same* diff, and an assign handed up to the parent and
  # back would always land one message later. The tracker section still owns
  # its own form, errors and writes.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok, load_derived(socket)}
  end

  # `tracker_type_preview` drives which `tracker.config.*` fields the nested
  # TrackerConfigComponent renders. It has to be reloaded after this section's
  # own write as well as on a parent update: the `{:workspace_updated, _}` a
  # write sends up is a second round trip, and until it lands the operator
  # would be looking at the previous tracker type's fields.
  defp load_derived(%{assigns: %{workspace: ws}} = socket) do
    assign(socket, :tracker_type_preview, cfg(ws, ["tracker", "type"], "none"))
  end

  @impl true
  def handle_event("save_config", %{"config" => params}, socket) do
    {merge_patch, merge_unset} = merge_settings_patch(params)
    {review_gate_patch, review_gate_unset} = review_gate_settings_patch(params)
    {review_automation_patch, review_automation_unset} = review_automation_settings_patch(params)
    {quota_patch, quota_unset} = quota_settings_patch(params)
    {conductor_patch, conductor_unset} = conductor_settings_patch(params)
    {pr_patrol_patch, pr_patrol_unset} = pr_patrol_settings_patch(params)
    {review_patrol_patch, review_patrol_unset} = review_patrol_settings_patch(params)

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
          |> maybe_put_map("quota", quota_patch)
          |> maybe_put_map("conductor", conductor_patch)
          |> maybe_put_map("pr_patrol", pr_patrol_patch)
          |> maybe_put_map("review_patrol", review_patrol_patch)

        unset =
          merge_unset ++
            review_gate_unset ++
            review_automation_unset ++
            routing_unset ++
            quota_unset ++ conductor_unset ++ pr_patrol_unset ++ review_patrol_unset

        case patch_config(socket.assigns.workspace, patch, unset) do
          {:ok, ws} ->
            {:noreply,
             socket
             |> apply_workspace(ws, "Configuration saved.")
             |> assign(:config_error, nil)
             |> load_derived()}

          {:error, msg} ->
            {:noreply, assign(socket, :config_error, msg)}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :config_error, msg)}
    end
  end

  # Live-updates which tracker.config.* fields are shown as the operator picks
  # a tracker type, before they've saved the config form — so switching types
  # doesn't require a round trip to see the right adapter fields appear.
  def handle_event("preview_tracker_type", %{"config" => params}, socket) do
    {:noreply, assign(socket, :tracker_type_preview, params["tracker_type"] || "none")}
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
        {:noreply, socket |> apply_workspace(updated) |> assign(:config_error, nil)}

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

  # ---- config patch builders ----

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

  # Builds the `quota.*` patch/unset pair (quota-aware dispatch throttle):
  # `on_exhaustion` is an enum with a `throttle` server default, while
  # `overage_alert_usd`/`throttle_threshold` are optional numbers kept as
  # their raw string form (the validator accepts either a number or its JSON
  # string form, same as `merge.watchdog_max_polls`) — a blank field unsets
  # rather than writing an empty string.
  defp quota_settings_patch(params) do
    {patch, unset} =
      case blank_to_nil(params["quota_on_exhaustion"]) do
        nil -> {%{}, ["quota.on_exhaustion"]}
        v -> {%{"on_exhaustion" => v}, []}
      end

    {patch, unset} =
      case blank_to_nil(params["quota_overage_alert_usd"]) do
        nil -> {patch, unset ++ ["quota.overage_alert_usd"]}
        v -> {Map.put(patch, "overage_alert_usd", v), unset}
      end

    case blank_to_nil(params["quota_throttle_threshold"]) do
      nil -> {patch, unset ++ ["quota.throttle_threshold"]}
      v -> {Map.put(patch, "throttle_threshold", v), unset}
    end
  end

  # Builds the `pr_patrol.*` patch/unset pair. `author_logins` is entered as a
  # comma-separated string and split into a list (same convention as
  # `review_automation.auto_authors`); the two `resolve_*_threads` booleans
  # are always written (checkbox-with-hidden-fallback, same as merge.*).
  defp pr_patrol_settings_patch(params) do
    patch = %{
      "resolve_bot_threads" => params["pr_patrol_resolve_bot_threads"] == "true",
      "resolve_human_threads" => params["pr_patrol_resolve_human_threads"] == "true"
    }

    case blank_to_nil(params["pr_patrol_author_logins"]) do
      nil ->
        {patch, ["pr_patrol.author_logins"]}

      v ->
        logins = v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        {Map.put(patch, "author_logins", logins), []}
    end
  end

  # Builds the `review_patrol.our_login` patch/unset pair.
  defp review_patrol_settings_patch(params) do
    case blank_to_nil(params["review_patrol_our_login"]) do
      nil -> {%{}, ["review_patrol.our_login"]}
      v -> {%{"our_login" => v}, []}
    end
  end

  # Builds the `conductor.max_concurrent` patch/unset pair — the per-workspace
  # concurrency cap, uncapped by default, kept as its raw string form (same
  # accepted-string-or-number pattern as `quota.*` above).
  defp conductor_settings_patch(params) do
    case blank_to_nil(params["conductor_max_concurrent"]) do
      nil -> {%{}, ["conductor.max_concurrent"]}
      v -> {%{"max_concurrent" => v}, []}
    end
  end

  # ---- form prefill ----

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

  defp review_required?(ws), do: cfg(ws, ["review", "required"]) in [true, "true"]

  defp pr_patrol_author_logins_text(ws) do
    case cfg(ws, ["pr_patrol", "author_logins"]) do
      list when is_list(list) -> Enum.join(list, ", ")
      _ -> ""
    end
  end

  defp auto_authors_text(ws) do
    case cfg(ws, ["review_automation", "auto_authors"]) do
      list when is_list(list) -> Enum.join(list, ", ")
      _ -> ""
    end
  end

  # ---- render ----

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :selected, :list, required: true
  attr :available, :list, required: true
  attr :target, :any, required: true
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
            phx-target={@target}
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
            phx-target={@target}
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
            phx-target={@target}
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
          phx-target={@target}
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

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- display:contents keeps these rows in the parent card-body flex
         flow, so extracting the section changes no layout. --%>
    <div class="contents">
      <div class="grid sm:grid-cols-2 gap-x-4 gap-y-3">
        <.agent_type_editor
          role="agent"
          target={@myself}
          label="Worker agent (agent.type)"
          selected={agent_type_list(@workspace, "agent")}
          available={@agent_types -- agent_type_list(@workspace, "agent")}
        />
        <.agent_type_editor
          role="review_agent"
          target={@myself}
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
        phx-change="preview_tracker_type"
        phx-target={@myself}
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
        <.input
          type="select"
          name="config[quota_on_exhaustion]"
          label="On quota exhaustion (quota.on_exhaustion)"
          options={[{"(unset — defaults to throttle)", ""} | Enum.map(@quota_modes, &{&1, &1})]}
          value={cfg(@workspace, ["quota", "on_exhaustion"], "")}
        />
        <.input
          type="text"
          name="config[quota_overage_alert_usd]"
          label="Overage alert threshold USD (quota.overage_alert_usd)"
          placeholder="e.g. 50"
          value={cfg(@workspace, ["quota", "overage_alert_usd"], "")}
        />
        <.input
          type="text"
          name="config[quota_throttle_threshold]"
          label="Throttle threshold (quota.throttle_threshold, 0-1]"
          placeholder="e.g. 0.8"
          value={cfg(@workspace, ["quota", "throttle_threshold"], "")}
        />
        <.input
          type="text"
          name="config[conductor_max_concurrent]"
          label="Max concurrent dispatches (conductor.max_concurrent)"
          placeholder="default: uncapped"
          value={cfg(@workspace, ["conductor", "max_concurrent"], "")}
        />
        <.input
          type="text"
          name="config[pr_patrol_author_logins]"
          label="PR-patrol authors (pr_patrol.author_logins)"
          placeholder="comma-separated forge logins; blank = patrol everyone"
          value={pr_patrol_author_logins_text(@workspace)}
        />
        <.input
          type="text"
          name="config[review_patrol_our_login]"
          label="Our forge login (review_patrol.our_login)"
          placeholder="e.g. arbiter-bot"
          value={cfg(@workspace, ["review_patrol", "our_login"], "")}
        />
        <label class="fieldset flex items-center gap-2 mt-6">
          <input type="hidden" name="config[pr_patrol_resolve_bot_threads]" value="false" />
          <input
            type="checkbox"
            name="config[pr_patrol_resolve_bot_threads]"
            value="true"
            checked={Workspace.pr_patrol_resolve_bot_threads?(@workspace)}
            class="toggle toggle-sm toggle-primary"
          />
          <span class="text-sm">
            Resolve addressed bot review threads (pr_patrol.resolve_bot_threads)
          </span>
        </label>
        <label class="fieldset flex items-center gap-2 mt-6">
          <input type="hidden" name="config[pr_patrol_resolve_human_threads]" value="false" />
          <input
            type="checkbox"
            name="config[pr_patrol_resolve_human_threads]"
            value="true"
            checked={Workspace.pr_patrol_resolve_human_threads?(@workspace)}
            class="toggle toggle-sm toggle-primary"
          />
          <span class="text-sm">
            Resolve addressed human review threads (pr_patrol.resolve_human_threads)
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
        Merger host details beyond the tracker below are still set with <code>arb config set</code>. Worker security lives in its own section below.
      </p>

      <.live_component
        :if={@tracker_type_preview != "none"}
        module={ArbiterWeb.WorkspaceDetail.TrackerConfigComponent}
        id="tracker-config"
        workspace={@workspace}
        type_preview={@tracker_type_preview}
      />
    </div>
    """
  end
end
