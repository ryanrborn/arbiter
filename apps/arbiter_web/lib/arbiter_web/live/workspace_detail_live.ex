defmodule ArbiterWeb.WorkspaceDetailLive do
  @moduledoc """
  Workspace detail + editor at `/workspaces/:id`.

  Surfaces every config section a non-CLI operator needs to onboard and run a
  workspace: tracker, merger, agent + review-agent, routing policy, review
  gate, standing orders, and secrets.

  This module is the **shell**: it loads the workspace, owns the page chrome
  and the name/prefix form, and composes one `Phoenix.LiveComponent` per
  settings section. Each section owns its own form, its own error assign and
  its own writes — see `ArbiterWeb.WorkspaceDetail.Shared` for the small
  contract they share:

    * `ArbiterWeb.WorkspaceDetail.PolicyConfigComponent` — the high-level
      enums (agent / review-agent provider pools, tracker type, merger
      strategy, routing policy, review gate, quota, conductor, patrols).
    * `ArbiterWeb.WorkspaceDetail.TrackerConfigComponent` — `tracker.config.*`,
      the adapter-specific fields scoped to the selected tracker type. Rendered
      *by* the policy component, whose select drives which fields show.
    * `ArbiterWeb.WorkspaceDetail.RepoPathsComponent` — `repos.*.path`.
    * `ArbiterWeb.WorkspaceDetail.RepoOverridesComponent` —
      `review_automation.repo_overrides`.
    * `ArbiterWeb.WorkspaceDetail.RoutingRulesComponent` /
      `ArbiterWeb.WorkspaceDetail.RoutingAdaptersComponent` — `routing.rules`
      and `routing.adapters`.
    * `ArbiterWeb.WorkspaceDetail.AgentModelConfigComponent` —
      `agent.config.*`, including per-provider tier overrides. The credential
      field is a **select over the workspace's existing secret names**
      (`secret:<key>`), never a free-text field that could take a raw token.
    * `ArbiterWeb.WorkspaceDetail.WorkerSecurityComponent` —
      `agent.security.*`, guard-gated.
    * `ArbiterWeb.WorkspaceDetail.StandingOrdersComponent` —
      `config.standing_orders`.
    * `ArbiterWeb.WorkspaceDetail.SecretsComponent` — the *names* of
      configured secrets only; plaintext values are never echoed back.
    * `ArbiterWeb.WorkspaceDetail.WorkerEnvVarsComponent` — the env vars
      injected into every worker's subprocess (`Arbiter.Worker.WorkerEnv`).

  Sections write independently but read one shared `@workspace`, so a section
  that writes sends `{:workspace_updated, ws}` back here and this module
  re-assigns it — that is what keeps a secret added in one section showing up
  in another's `credentials_ref` select, without either reaching into the
  other.

  All writes go through Ash actions directly (same VM as the API controller),
  so the server-side `ValidateConfig` guardrails apply identically.
  """

  use ArbiterWeb, :live_view

  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Changes.ValidateConfig
  alias ArbiterWeb.WorkspaceDetail

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Ash.get(Workspace, id) do
      {:ok, ws} ->
        {:ok,
         socket
         |> assign(:workspace, ws)
         |> assign(:not_found, false)
         |> assign(:details_error, nil)
         |> assign(:tracker_types, Workspace.valid_tracker_types())
         |> assign(:merger_strategies, Workspace.valid_merger_strategies())
         |> assign(:agent_types, Agents.valid_agent_types())
         |> assign(:routing_policies, Routing.valid_policies())
         |> assign(:review_automation_modes, ValidateConfig.valid_review_automation_modes())
         |> assign(:quota_modes, ValidateConfig.valid_quota_modes())
         |> assign(:security_modes, SecurityPolicy.valid_modes())
         |> assign(:security_filesystems, SecurityPolicy.valid_filesystems())
         |> assign(:safe_default_categories, SecurityPolicy.safe_default_categories())}

      _ ->
        {:ok, assign(socket, workspace: nil, not_found: true)}
    end
  end

  # ---- workspace details (name/prefix) ----
  #
  # The only form still handled here: it writes workspace *attributes* rather
  # than config, so it shares nothing with the section components.

  @impl true
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

  # ---- section callbacks ----

  # A section wrote. Re-assign the shared workspace so *every* section
  # re-renders off the new config, not just the one that wrote it.
  @impl true
  def handle_info({:workspace_updated, ws}, socket) do
    {:noreply, assign(socket, :workspace, ws)}
  end

  # Flash belongs to the LiveView, not the component: a component's `@flash`
  # is seeded empty and only merged into the parent's on redirect, so a
  # `put_flash/3` inside a section would never reach the `Layouts.app` flash
  # group. Sections hand the message up instead.
  def handle_info({:workspace_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
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
            <.live_component
              module={WorkspaceDetail.PolicyConfigComponent}
              id="policy-config"
              workspace={@workspace}
              agent_types={@agent_types}
              tracker_types={@tracker_types}
              merger_strategies={@merger_strategies}
              routing_policies={@routing_policies}
              review_automation_modes={@review_automation_modes}
              quota_modes={@quota_modes}
            />
            <.live_component
              module={WorkspaceDetail.RepoOverridesComponent}
              id="repo-overrides-section"
              workspace={@workspace}
              review_automation_modes={@review_automation_modes}
            />
            <.live_component
              module={WorkspaceDetail.RepoPathsComponent}
              id="repo-paths-section"
              workspace={@workspace}
            />
            <.live_component
              module={WorkspaceDetail.RoutingRulesComponent}
              id="routing-rules-section"
              workspace={@workspace}
            />
            <.live_component
              module={WorkspaceDetail.RoutingAdaptersComponent}
              id="routing-adapters-section"
              workspace={@workspace}
            />
          </div>
        </section>

        <.live_component
          module={WorkspaceDetail.AgentModelConfigComponent}
          id="agent-model-config"
          workspace={@workspace}
          agent_types={@agent_types}
        />

        <.live_component
          module={WorkspaceDetail.WorkerSecurityComponent}
          id="agent-security"
          workspace={@workspace}
          security_modes={@security_modes}
          security_filesystems={@security_filesystems}
          safe_default_categories={@safe_default_categories}
        />

        <.live_component
          module={WorkspaceDetail.StandingOrdersComponent}
          id="standing-orders-section"
          workspace={@workspace}
        />

        <.live_component
          module={WorkspaceDetail.SecretsComponent}
          id="secrets-section"
          workspace={@workspace}
        />

        <.live_component
          module={WorkspaceDetail.WorkerEnvVarsComponent}
          id="worker-env-section"
          workspace={@workspace}
        />
      </div>
    </Layouts.app>
    """
  end
end
