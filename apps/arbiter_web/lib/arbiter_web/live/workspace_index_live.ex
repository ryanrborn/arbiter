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
  require Ash.Query

  @valid_tracker_types Workspace.valid_tracker_types()
  @valid_merger_strategies Workspace.valid_merger_strategies()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:live, connected?(socket))
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
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <.index_header
          icon="hero-building-office-2"
          title="Workspaces"
          count={length(@workspaces)}
          subtitle="Tracker, merger, agent routing, standing orders and secrets — per workspace."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <.live_badge live={@live} />
              <.button
                :if={!@creating}
                phx-click="new"
                variant="primary"
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-plus" class="size-4" /> New workspace
              </.button>
            </div>
          </:actions>
        </.index_header>

        <section :if={@creating} class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold text-sm">Create a workspace</h2>
            <.form for={%{}} as={:workspace} phx-submit="create" class="grid sm:grid-cols-2 gap-x-4">
              <.input
                name="workspace[name]"
                label="Name"
                value=""
                required
                placeholder="acme-backend"
              />
              <.input name="workspace[prefix]" label="Prefix" value="bd" placeholder="bd" />
              <.input
                type="select"
                name="workspace[tracker_type]"
                label="Tracker type"
                options={Enum.map(@tracker_types, &{&1, &1})}
                value="none"
              />
              <.input
                type="select"
                name="workspace[merger_strategy]"
                label="Merger strategy"
                options={Enum.map(@merger_strategies, &{&1, &1})}
                value="direct"
              />
              <div class="sm:col-span-2">
                <.input name="workspace[description]" label="Description (optional)" value="" />
              </div>
              <p :if={@create_error} class="sm:col-span-2 text-sm text-error">{@create_error}</p>
              <div class="sm:col-span-2 flex gap-2 mt-1">
                <.button type="submit" variant="primary" class="btn btn-sm btn-primary">
                  Create
                </.button>
                <.button type="button" phx-click="cancel_new" class="btn btn-sm btn-ghost">
                  Cancel
                </.button>
              </div>
            </.form>
          </div>
        </section>

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-2">
            <.empty_state :if={@workspaces == []} id="ws-empty" icon="hero-building-office-2">
              No workspaces yet.
            </.empty_state>

            <ul :if={@workspaces != []} id="workspaces" class="flex flex-col gap-1.5">
              <li
                :for={ws <- @workspaces}
                class="rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors duration-150 hover:bg-base-300/40"
              >
                <.link navigate={~p"/workspaces/#{ws.id}"} class="group block">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="badge badge-sm badge-ghost font-mono shrink-0">{ws.prefix}</span>
                    <span class="text-sm font-medium group-hover:text-primary transition-colors">
                      {ws.name}
                    </span>
                    <span class="badge badge-sm badge-outline">tracker: {tracker_type(ws)}</span>
                    <span class="badge badge-sm badge-outline">merge: {merger_strategy(ws)}</span>
                    <span
                      :if={standing_order_count(ws) > 0}
                      class="badge badge-sm badge-info badge-soft"
                    >
                      {standing_order_count(ws)} order(s)
                    </span>
                    <span
                      :if={secret_count(ws) > 0}
                      class="badge badge-sm badge-warning badge-soft gap-1"
                    >
                      <.icon name="hero-key" class="size-3" /> {secret_count(ws)}
                    </span>
                    <code class="ml-auto text-xs text-base-content/50 shrink-0">{ws.id}</code>
                  </div>
                  <p :if={ws.description not in [nil, ""]} class="text-xs text-base-content/60 mt-1">
                    {ws.description}
                  </p>
                </.link>
              </li>
            </ul>
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end
end
