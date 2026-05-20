defmodule GtElixirWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView at `/` — real-time view of:

    * Active polecats (name, current step, bead, runtime)
    * Recent beads (last 20 by `updated_at` desc)
    * PRs in flight (placeholder — Phase 4 supervisor will register
      Refinery instances per workspace and expose their state)
    * Escalations (placeholder — no Escalation resource yet)

  ## PubSub topics

  Subscribed at mount:
    * `"beads"`     — `{:bead_lifecycle, event, issue}` from
                      `GtElixir.Beads.Issue.broadcast_lifecycle/2`.
    * `"polecats"`  — `{:polecat_lifecycle, event, snapshot}` from
                      `GtElixir.Polecat.broadcast_lifecycle/2`.

  Both topics fire on every relevant write. The LiveView refreshes the
  affected section by re-reading the data (deliberately naive — Phase 5
  can optimize once we have profile evidence that the simple refresh is
  too costly).
  """

  use GtElixirWeb, :live_view

  alias GtElixir.Beads.Issue
  alias GtElixir.Polecat
  alias GtElixir.Vernacular
  require Ash.Query

  @beads_topic "beads"
  @polecats_topic "polecats"

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(GtElixir.PubSub, @beads_topic)
      Phoenix.PubSub.subscribe(GtElixir.PubSub, @polecats_topic)
    end

    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:live, live?)
     |> assign(:worker_label, Vernacular.label(:worker))
     |> refresh_polecats()
     |> refresh_recent_beads()}
  end

  @impl true
  def handle_info({:bead_lifecycle, _event, _issue}, socket) do
    {:noreply, refresh_recent_beads(socket)}
  end

  def handle_info({:polecat_lifecycle, _event, _snapshot}, socket) do
    {:noreply, refresh_polecats(socket)}
  end

  # ---- data ----

  defp refresh_polecats(socket) do
    polecats =
      try do
        Polecat.list_children()
      rescue
        _ -> []
      end

    assign(socket, :polecats, polecats)
  end

  defp refresh_recent_beads(socket) do
    beads =
      Issue
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(20)
      |> Ash.read!()

    assign(socket, :recent_beads, beads)
  end

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp status_badge_class(:open), do: "badge badge-success"
  defp status_badge_class(:in_progress), do: "badge badge-info"
  defp status_badge_class(:closed), do: "badge badge-ghost"
  defp status_badge_class(_), do: "badge"

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Dashboard</h1>
        <span
          id="live-indicator"
          class={[
            "badge badge-sm",
            if(@live, do: "badge-success", else: "badge-warning")
          ]}
          title={
            if @live,
              do: "WebSocket connected — updates arrive in real time",
              else: "Static render — refresh the page to reconnect"
          }
        >
          <%= if @live do %>
            ● live
          <% else %>
            ⚠ stale (refresh)
          <% end %>
        </span>
      </div>

      <div class="grid grid-cols-2 gap-6">
        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">
            Active {String.capitalize(@worker_label)}s ({length(@polecats)})
          </h2>
          <%= if @polecats == [] do %>
            <p class="text-base-content/60 italic">No active {@worker_label}s.</p>
          <% else %>
            <table class="table table-sm" id="active-polecats">
              <thead>
                <tr>
                  <th>Bead</th>
                  <th>Step</th>
                  <th>Status</th>
                  <th>Runtime</th>
                </tr>
              </thead>
              <tbody>
                <%= for p <- @polecats do %>
                  <tr>
                    <td>
                      <.link
                        navigate={~p"/polecats/#{p.bead_id}"}
                        class="link link-hover"
                      >
                        <code class="text-xs">{p.bead_id}</code>
                      </.link>
                    </td>
                    <td>{p.current_step}</td>
                    <td>
                      <span class="badge badge-sm">{p.status}</span>
                    </td>
                    <td class="text-xs">
                      {humanize_seconds(runtime_seconds(p.started_at, @now))}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </section>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">
            Recent beads ({length(@recent_beads)})
          </h2>
          <table class="table table-sm" id="recent-beads">
            <thead>
              <tr>
                <th>ID</th>
                <th>Title</th>
                <th>Status</th>
                <th>P</th>
              </tr>
            </thead>
            <tbody>
              <%= for b <- @recent_beads do %>
                <tr>
                  <td><code class="text-xs">{b.id}</code></td>
                  <td>{b.title}</td>
                  <td>
                    <span class={status_badge_class(b.status)}>{b.status}</span>
                  </td>
                  <td class="text-xs">P{b.priority}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </section>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">PRs in flight</h2>
          <p class="text-base-content/60 italic" id="prs-empty">
            No refineries running. (Phase 4 will register Refinery instances
            per workspace and surface their queues here.)
          </p>
        </section>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">Escalations</h2>
          <p class="text-base-content/60 italic" id="escalations-empty">
            No escalations. (Escalation resource is a Phase 5 follow-up.)
          </p>
        </section>
      </div>
    </div>
    """
  end
end
