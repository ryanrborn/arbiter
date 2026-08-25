defmodule ArbiterWeb.WorkspaceDetailLive do
  @moduledoc """
  Workspace detail + editor at `/workspaces/:id`.

  Surfaces every config section a non-CLI operator needs to onboard and run a
  workspace: repos, policy, agent models, routing, standing orders, tracker,
  secrets and security. Those eight are the **rail** down the left of the
  panel; the body shows exactly one of them at a time.

  Every pane stays mounted, hidden with CSS rather than unmounted. A section
  is a live component that owns real state — an open secret modal, a pending
  security downgrade, a half-typed routing rule — and throwing that away every
  time the operator glances at another section would be its own bug.

  This module is the **shell**: it loads the workspace, owns the rail, the
  workspace-identity form and the install-wide dispatch switch, and composes
  one `Phoenix.LiveComponent` per settings section. Each section owns its own
  form, its own error assign and its own writes — see
  `ArbiterWeb.WorkspaceDetail.Shared` for the small contract they share:

    * `ArbiterWeb.WorkspaceDetail.PolicyConfigComponent` — the high-level
      enums (agent / review-agent provider pools, tracker type, merger
      strategy, routing policy, review gate, quota, conductor, patrols).
    * `ArbiterWeb.WorkspaceDetail.TrackerConfigComponent` — `tracker.config.*`,
      the adapter-specific fields scoped to the selected tracker type. Rendered
      *by* the policy component, whose select drives which fields show.
    * `ArbiterWeb.WorkspaceDetail.RepoPathsComponent` — `repo_paths.*`.
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

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Agents
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Changes.ValidateConfig
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.WorkspaceDetail

  # The rail, in the order an operator onboards a workspace: point it at code,
  # decide how work flows, then how it is run, then what it is allowed to do.
  @sections [
    {"repos", "Repos"},
    {"policy", "Policy"},
    {"agent_models", "Agent models"},
    {"routing", "Routing"},
    {"standing_orders", "Standing orders"},
    {"tracker", "Tracker"},
    {"secrets", "Secrets"},
    {"security", "Security"}
  ]

  @section_slugs Enum.map(@sections, &elem(&1, 0))

  # The scheduler is a GenServer that can be down (or slow) without the config
  # screen being wrong, so every call to it is guarded — same contract as the
  # board's, see `ArbiterWeb.BoardLive`.
  @scheduler_call_timeout_ms 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Ash.get(Workspace, id) do
      {:ok, ws} ->
        {:ok,
         socket
         |> assign(:workspace, ws)
         |> assign(:not_found, false)
         |> assign(:details_error, nil)
         |> assign(:section, "repos")
         |> assign(:sections, @sections)
         |> assign(:autodispatch, autodispatch_on?())
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

  # ---- rail ----

  @impl true
  def handle_event("section", %{"section" => slug}, socket) when slug in @section_slugs do
    {:noreply, assign(socket, :section, slug)}
  end

  # ---- workspace details (name/prefix) ----
  #
  # The only settings form still handled here: it writes workspace *attributes*
  # rather than config, so it shares nothing with the section components.

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

  # Auto-dispatch is the board scheduler, which is install-wide rather than
  # per-workspace — the switch is shown here because this is where an operator
  # comes to decide how work flows, but flipping it stops or starts promotion
  # for *every* workspace. The consequence line says so.
  def handle_event("toggle_autodispatch", _params, socket) do
    on? = socket.assigns.autodispatch

    wrote? =
      guarded(
        fn ->
          if on?, do: Autopilot.pause(Autopilot), else: Autopilot.resume(Autopilot)
          true
        end,
        false
      )

    # Flash what the scheduler actually did, not what we asked it to. A dead or
    # unreachable autopilot leaves the switch where it was, and saying
    # "paused." over a scheduler that never heard us is the one message an
    # operator must not be given.
    socket = assign(socket, :autodispatch, autodispatch_on?())

    {:noreply,
     if wrote? do
       put_flash(
         socket,
         :info,
         if(on?, do: "Auto-dispatch paused.", else: "Auto-dispatch resumed.")
       )
     else
       put_flash(
         socket,
         :error,
         "The board scheduler did not answer — auto-dispatch is unchanged."
       )
     end}
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

  # Catch-all: this view lives in `live_session :default` alongside AppShell
  # hooks (coordinator inbox tick/subscription) that broadcast to every
  # mounted LiveView. Without this clause, any message those hooks don't
  # `:halt` crashes this view with a FunctionClauseError.
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ---- scheduler ----

  # Two questions, not one: `running?/1` answers "is there an autopilot at all"
  # (it takes a server, never a timeout), `paused?/2` answers "is it draining
  # the queue". The switch is about the second — an install with no autopilot
  # reads as off, same as `BoardLive`.
  defp autodispatch_on?,
    do:
      guarded(
        fn ->
          Autopilot.running?(Autopilot) and
            not Autopilot.paused?(Autopilot, @scheduler_call_timeout_ms)
        end,
        false
      )

  defp guarded(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  # ---- render ----

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="mx-auto flex max-w-[1100px] flex-col gap-4 p-4 sm:p-6">
        <Feedback.empty_state icon="hero-building-office-2" detail="no workspace with that id">
          Workspace not found.
        </Feedback.empty_state>
        <Navigation.back_link href={~p"/workspaces"} label="Back to workspaces" />
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="mx-auto flex max-w-[1100px] flex-col gap-5 p-4 sm:p-6">
        <Domain.index_header
          icon="hero-cog-6-tooth"
          title={@workspace.name}
          subtitle="Tracker, merger, agent routing, standing orders and secrets — per workspace."
        >
          <:actions>
            <span class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]">
              {@workspace.prefix}-
            </span>
            <Feedback.live_badge id="ws-live" live={@live} />
          </:actions>
        </Domain.index_header>

        <div class="grid min-h-[400px] grid-cols-[168px_minmax(0,1fr)] overflow-hidden rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)]">
          <nav
            id="ws-rail"
            aria-label="Workspace settings"
            class="flex flex-col gap-px border-r border-solid border-[var(--border-default)] py-[14px]"
          >
            <button
              :for={{slug, label} <- @sections}
              type="button"
              phx-click="section"
              phx-value-section={slug}
              aria-selected={to_string(@section == slug)}
              class={[
                "cursor-pointer border-l-[var(--border-accent-width)] border-solid px-[14px] py-[7px] text-left",
                "font-[family-name:var(--font-sans)] text-[11.5px] leading-[1.3]",
                @section == slug &&
                  "border-[var(--accent-primary)] bg-[var(--arb-raised)] font-medium text-[var(--text-title)]",
                @section != slug &&
                  "border-transparent font-normal text-[var(--text-secondary)] hover:bg-[var(--arb-raised)]"
              ]}
            >
              {label}
            </button>
          </nav>

          <div class="flex min-w-0 flex-col gap-4 px-[18px] pt-[18px] pb-[24px]">
            <%!-- Every header stays in the DOM alongside its pane, so the one
                 on screen is always the one the rail has selected. --%>
            <.section_header
              :for={{slug, label} <- @sections}
              name={slug}
              section={@section}
              title={label}
              context={section_context(slug, @workspace)}
            />

            <.live_component
              module={WorkspaceDetail.RepoPathsComponent}
              id="repo-paths-section"
              section={@section}
              workspace={@workspace}
            />

            <%!-- Workspace identity leads the Policy pane: name and prefix are
                 what every other setting is scoped to. --%>
            <.pane name="policy" section={@section}>
              <.form for={%{}} as={:details} phx-submit="save_details">
                <.rows>
                  <.setting_row
                    name="Workspace name"
                    consequence="what this workspace is called in the board, the CLI and every worker prompt"
                  >
                    <:control>
                      <Forms.input name="details[name]" value={@workspace.name} size="sm" required />
                    </:control>
                  </.setting_row>
                  <.setting_row
                    name="Issue prefix"
                    consequence="new issue IDs get this prefix; it does not rename existing issue IDs"
                  >
                    <:control>
                      <Forms.input
                        name="details[prefix]"
                        value={@workspace.prefix}
                        size="sm"
                        pattern="[a-z][a-z0-9]*"
                        maxlength="16"
                        required
                      />
                    </:control>
                  </.setting_row>
                  <.toggle_row
                    name="Auto-dispatch ready issues"
                    consequence="Ready issues promote themselves each scheduler tick, within slot, dependency, file-overlap and quota limits; install-wide"
                    checked={@autodispatch}
                    click="toggle_autodispatch"
                  />
                </.rows>
                <div class="mt-3 flex items-center gap-3">
                  <Core.button type="submit" variant="primary" size="sm">Save details</Core.button>
                  <p :if={@details_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
                    {@details_error}
                  </p>
                </div>
              </.form>
            </.pane>

            <%!-- The tracker pane is rendered *by* the policy component, whose
                 select drives which adapter fields show; its header has to
                 come from here, ahead of it in the DOM. Panes for other
                 sections are hidden, so DOM order across sections is free. --%>
            <.live_component
              module={WorkspaceDetail.PolicyConfigComponent}
              id="policy-config"
              section={@section}
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
              section={@section}
              workspace={@workspace}
              review_automation_modes={@review_automation_modes}
            />

            <.live_component
              module={WorkspaceDetail.AgentModelConfigComponent}
              id="agent-model-config"
              section={@section}
              workspace={@workspace}
              agent_types={@agent_types}
            />

            <.live_component
              module={WorkspaceDetail.RoutingRulesComponent}
              id="routing-rules-section"
              section={@section}
              workspace={@workspace}
            />

            <.live_component
              module={WorkspaceDetail.RoutingAdaptersComponent}
              id="routing-adapters-section"
              section={@section}
              workspace={@workspace}
            />

            <.live_component
              module={WorkspaceDetail.StandingOrdersComponent}
              id="standing-orders-section"
              section={@section}
              workspace={@workspace}
            />

            <.live_component
              module={WorkspaceDetail.SecretsComponent}
              id="secrets-section"
              section={@section}
              workspace={@workspace}
            />

            <.live_component
              module={WorkspaceDetail.WorkerSecurityComponent}
              id="agent-security"
              section={@section}
              workspace={@workspace}
              security_modes={@security_modes}
              security_filesystems={@security_filesystems}
              safe_default_categories={@safe_default_categories}
            />

            <.live_component
              module={WorkspaceDetail.WorkerEnvVarsComponent}
              id="worker-env-section"
              section={@section}
              workspace={@workspace}
            />
          </div>
        </div>

        <Navigation.back_link href={~p"/"} label="Back to board" />
      </div>
    </Layouts.app>
    """
  end

  # Right-aligned note on the section header. Repos counts what it holds
  # because that count is the thing an operator is checking; every other
  # section says which workspace it is editing, which is the thing they are
  # about to get wrong with two tabs open.
  defp section_context("repos", ws), do: "#{map_size(repo_paths_map(ws))} paths"
  defp section_context(_slug, ws), do: "workspace: #{ws.name}"

  defp repo_paths_map(ws) do
    case cfg(ws, ["repo_paths"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end
end
