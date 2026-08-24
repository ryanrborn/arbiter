defmodule ArbiterWeb.WorkspaceIndexLive do
  @moduledoc """
  Index of every workspace at `/workspaces` — the operator's entry point for
  workspace management. Lists each workspace with its prefix, tracker, merger,
  and secret count, click-through to the detail page where config, standing
  orders, and secrets are editable.

  Read-only list; the "New workspace" action opens an inline create form so a
  non-CLI operator can onboard a workspace end-to-end without dropping to
  `arb workspace create`.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms
  alias ArbiterWeb.CoreComponents.Navigation
  require Ash.Query

  @valid_tracker_types Workspace.valid_tracker_types()
  @valid_merger_strategies Workspace.valid_merger_strategies()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:creating, false)
     |> assign(:create_error, nil)
     |> assign(:tracker_types, @valid_tracker_types)
     |> assign(:merger_strategies, @valid_merger_strategies)
     |> refresh()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, create_error: nil)}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, creating: false, create_error: nil)}
  end

  def handle_event("create", %{"workspace" => params}, socket) do
    name = params["name"] |> to_string() |> String.trim()
    prefix = params["prefix"] |> to_string() |> String.trim()
    tracker_type = params["tracker_type"] || "none"
    merger_strategy = params["merger_strategy"] || "direct"
    description = params["description"] |> to_string() |> String.trim()

    attrs = %{
      name: name,
      prefix: if(prefix == "", do: "bd", else: prefix),
      description: if(description == "", do: nil, else: description),
      config: %{
        "tracker" => %{"type" => tracker_type},
        "merge" => %{"strategy" => merger_strategy}
      }
    }

    case Ash.create(Workspace, attrs) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> assign(creating: false, create_error: nil)
         |> put_flash(:info, "Created workspace #{ws.name}.")
         |> push_navigate(to: ~p"/workspaces/#{ws.id}")}

      {:error, err} ->
        {:noreply, assign(socket, :create_error, error_message(err))}
    end
  end

  defp refresh(socket) do
    workspaces =
      Workspace
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!()

    assign(socket, :workspaces, workspaces)
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(&Exception.message/1)
    |> Enum.join("; ")
  end

  defp error_message(err), do: Exception.message(err)

  # ---- view helpers ----

  defp tracker_type(ws), do: get_in(ws.config || %{}, ["tracker", "type"]) || "none"
  defp merger_strategy(ws), do: get_in(ws.config || %{}, ["merge", "strategy"]) || "direct"

  defp standing_order_count(ws) do
    case get_in(ws.config || %{}, ["standing_orders"]) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp secret_count(ws), do: ws |> Workspace.secrets_map() |> map_size()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas} live={@live}>
      <div class="mx-auto flex max-w-[1100px] flex-col gap-5 p-4 sm:p-6">
        <Domain.index_header
          icon="hero-cog-6-tooth"
          title="Workspaces"
          count={length(@workspaces)}
          subtitle="Tracker, merger, agent routing, standing orders and secrets — per workspace."
        >
          <:actions>
            <Feedback.live_badge id="ws-index-live" live={@live} />
            <Core.button :if={!@creating} phx-click="new" variant="primary" size="sm">
              New workspace
            </Core.button>
          </:actions>
        </Domain.index_header>

        <div
          :if={@creating}
          class="rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] p-4"
        >
          <h2 class="m-0 mb-3 text-[13px] font-medium text-[var(--text-title)]">
            Create a workspace
          </h2>
          <.form for={%{}} as={:workspace} phx-submit="create" class="flex flex-col gap-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <Forms.input
                name="workspace[name]"
                label="Name"
                hint="how the workspace is addressed on the CLI and in every dispatch"
                value=""
                size="sm"
                required
                placeholder="acme-backend"
              />
              <Forms.input
                name="workspace[prefix]"
                label="Prefix"
                hint="leads every issue id this workspace mints; changing it later does not rename existing ids"
                value="bd"
                size="sm"
                placeholder="bd"
              />
              <Forms.select
                name="workspace[tracker_type]"
                label="Tracker type"
                options={Enum.map(@tracker_types, &{&1, &1})}
                value="none"
                size="sm"
              />
              <Forms.select
                name="workspace[merger_strategy]"
                label="Merger strategy"
                options={Enum.map(@merger_strategies, &{&1, &1})}
                value="direct"
                size="sm"
              />
            </div>
            <Forms.input
              name="workspace[description]"
              label="Description (optional)"
              value=""
              size="sm"
              mono={false}
            />
            <p :if={@create_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
              {@create_error}
            </p>
            <div class="flex gap-2">
              <Core.button type="submit" variant="primary" size="sm">Create</Core.button>
              <Core.button type="button" variant="ghost" size="sm" phx-click="cancel_new">
                Cancel
              </Core.button>
            </div>
          </.form>
        </div>

        <Feedback.empty_state
          :if={@workspaces == []}
          icon="hero-cog-6-tooth"
          detail="no workspaces yet"
        >
          Create one to register repos, a tracker and the agent routing every dispatch reads.
        </Feedback.empty_state>

        <ul
          :if={@workspaces != []}
          id="workspaces"
          class="m-0 flex list-none flex-col gap-px overflow-hidden rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--border-default)] p-0"
        >
          <li :for={ws <- @workspaces} class="bg-[var(--surface-chrome)]">
            <.link
              navigate={~p"/workspaces/#{ws.id}"}
              class="group block px-3 py-[10px] hover:bg-[var(--arb-raised)]"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class={meta_chip()}>{ws.prefix}</span>
                <span class="text-[13px] font-medium text-[var(--text-title)]">{ws.name}</span>
                <span class={meta_chip()}>tracker: {tracker_type(ws)}</span>
                <span class={meta_chip()}>merge: {merger_strategy(ws)}</span>
                <span :if={standing_order_count(ws) > 0} class={meta_chip()}>
                  {standing_order_count(ws)} order(s)
                </span>
                <span :if={secret_count(ws) > 0} class={meta_chip()}>
                  <Core.icon name="hero-key" size={11} /> {secret_count(ws)}
                </span>
                <span class="ml-auto flex-none font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-label)]">
                  {ws.id}
                </span>
              </div>
              <p
                :if={ws.description not in [nil, ""]}
                class="mt-1 mb-0 text-[11.5px] leading-[1.5] text-[var(--text-secondary)]"
              >
                {ws.description}
              </p>
            </.link>
          </li>
        </ul>

        <Navigation.back_link href={~p"/"} label="Back to board" />
      </div>
    </Layouts.app>
    """
  end

  defp meta_chip do
    "inline-flex flex-none items-center gap-1 rounded-[var(--radius-chip)] border " <>
      "border-solid border-[var(--border-default)] px-[6px] py-[1px] " <>
      "font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)]"
  end
end
