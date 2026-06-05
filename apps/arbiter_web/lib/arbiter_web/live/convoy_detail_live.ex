defmodule ArbiterWeb.ConvoyDetailLive do
  @moduledoc """
  Per-campaign detail view at `/convoys/:id` — the convoy record, its
  issue-progress aggregate, and the full list of member directives, each
  linking through to its own detail page. Re-renders live on
  `:bead_lifecycle` events since a member transition changes the progress and
  may auto-close a system-managed convoy.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Convoy
  alias Arbiter.Beads.Workspace
  alias Arbiter.Vernacular

  @beads_topic "beads"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @beads_topic)

    {:ok,
     socket
     |> assign(:convoy_id, id)
     |> assign(:live, connected?(socket))
     |> assign(:convoy_label, Vernacular.label(:batch))
     |> assign(:issue_label, Vernacular.label(:issue))
     |> assign(:workspace_label, Vernacular.label(:workspace))
     |> refresh()}
  end

  @impl true
  def handle_info({:bead_lifecycle, _event, _issue}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    socket
    |> refresh_convoy()
    |> refresh_workspace()
  end

  defp refresh_convoy(socket) do
    convoy =
      case Ash.get(Convoy, socket.assigns.convoy_id,
             load: [:total_issues, :closed_issues, :issues]
           ) do
        {:ok, c} -> c
        {:error, _} -> nil
      end

    assign(socket, :convoy, convoy)
  end

  defp refresh_workspace(%{assigns: %{convoy: %Convoy{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  # Member issues, non-closed first, then by id, for a stable, useful order.
  defp sorted_issues(%Convoy{issues: issues}) when is_list(issues) do
    Enum.sort_by(issues, fn i -> {i.status == :closed, i.id} end)
  end

  defp sorted_issues(_), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-sm text-base-content/60">
              <.icon name="hero-rectangle-stack" class="size-4" />
              <span>{String.capitalize(@convoy_label)}</span>
              <code class="text-base-content/80">{@convoy_id}</code>
            </div>
            <h1
              :if={@convoy}
              class="text-2xl font-bold tracking-tight mt-1 truncate"
              title={@convoy.title}
            >
              {@convoy.title}
            </h1>
            <h1 :if={!@convoy} class="text-2xl font-bold tracking-tight mt-1">
              {String.capitalize(@convoy_label)} not found
            </h1>
          </div>
          <.live_badge live={@live} />
        </div>

        <%= if @convoy do %>
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Record + progress --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-4">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-document-text" class="size-5 text-base-content/70" />
                  {String.capitalize(@convoy_label)} record
                </h2>

                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
                  <dt class="font-medium text-base-content/60">Status</dt>
                  <dd>
                    <span class={["badge badge-sm", status_badge_class(@convoy.status)]}>
                      {@convoy.status}
                    </span>
                  </dd>

                  <dt class="font-medium text-base-content/60">Lifecycle</dt>
                  <dd>
                    <span class="badge badge-ghost badge-sm font-mono">{@convoy.lifecycle}</span>
                  </dd>

                  <dt class="font-medium text-base-content/60">
                    {String.capitalize(@workspace_label)}
                  </dt>
                  <dd>
                    <%= if @workspace do %>
                      {@workspace.name}
                      <code class="badge badge-ghost badge-sm font-mono ml-1">
                        {@workspace.prefix}
                      </code>
                    <% else %>
                      <span class="text-base-content/50 italic">(none)</span>
                    <% end %>
                  </dd>

                  <%= if @convoy.closed_reason do %>
                    <dt class="font-medium text-base-content/60">Closed reason</dt>
                    <dd class="text-base-content/80">{@convoy.closed_reason}</dd>
                  <% end %>
                </dl>

                <div class="space-y-1">
                  <div class="flex items-center justify-between text-sm">
                    <span class="font-medium text-base-content/60">Progress</span>
                    <span class="font-mono tabular-nums text-base-content/70">
                      {@convoy.closed_issues}/{@convoy.total_issues} closed
                    </span>
                  </div>
                  <progress
                    class="progress progress-success w-full h-2"
                    value={@convoy.closed_issues}
                    max={max(@convoy.total_issues, 1)}
                  >
                  </progress>
                </div>
              </div>
            </section>

            <%!-- Member issues --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm lg:col-span-2">
              <div class="card-body p-4 gap-4">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-queue-list" class="size-5 text-base-content/70" />
                  {cap_plural(@issue_label)} ({@convoy.total_issues})
                </h2>

                <.empty_state
                  :if={sorted_issues(@convoy) == []}
                  id="convoy-issues-empty"
                  icon="hero-clipboard-document-list"
                >
                  No {plural(@issue_label)} tracked in this {@convoy_label} yet.
                </.empty_state>

                <ul
                  :if={sorted_issues(@convoy) != []}
                  id="convoy-issues"
                  class="flex flex-col gap-1.5"
                >
                  <li
                    :for={i <- sorted_issues(@convoy)}
                    class="rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors duration-150 hover:bg-base-300/40"
                  >
                    <div class="flex items-center gap-2">
                      <.link navigate={~p"/beads/#{i.id}"} class="min-w-0 flex-1 group">
                        <div class="flex items-center gap-2">
                          <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
                            {i.id}
                          </code>
                          <span
                            class="truncate text-sm group-hover:text-primary transition-colors"
                            title={i.title}
                          >
                            {i.title}
                          </span>
                        </div>
                      </.link>
                      <span class={["badge badge-sm shrink-0", status_badge_class(i.status)]}>
                        {i.status}
                      </span>
                    </div>
                  </li>
                </ul>
              </div>
            </section>
          </div>
        <% else %>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-8 items-center text-center gap-2">
              <.icon name="hero-question-mark-circle" class="size-12 text-base-content/30" />
              <p class="text-base-content/70">
                {String.capitalize(@convoy_label)} <code class="text-sm">{@convoy_id}</code>
                not found.
              </p>
            </div>
          </section>
        <% end %>

        <.back_link navigate={~p"/convoys"} label={"Back to all #{plural(@convoy_label)}"} />
      </div>
    </Layouts.app>
    """
  end

  defp status_badge_class(:open), do: "badge-success"
  defp status_badge_class(:in_progress), do: "badge-info"
  defp status_badge_class(:closed), do: "badge-ghost"
  defp status_badge_class(_), do: ""
end
