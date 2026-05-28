defmodule ArbiterWeb.DashboardLive do
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
                      `Arbiter.Beads.Issue.broadcast_lifecycle/2`.
    * `"polecats"`  — `{:polecat_lifecycle, event, snapshot}` from
                      `Arbiter.Polecat.broadcast_lifecycle/2`.
    * `"messages:<workspace_id>"` — `{:new_message, message}` from
                      `Arbiter.Messages.Message.broadcast_new/1`, one
                      subscription per workspace known at mount. Drives the
                      live notifications feed.

  Both topics fire on every relevant write. The LiveView refreshes the
  affected section by re-reading the data (deliberately naive — Phase 5
  can optimize once we have profile evidence that the simple refresh is
  too costly).
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Worktree
  alias Arbiter.Vernacular
  require Ash.Query

  @beads_topic "beads"
  @polecats_topic "polecats"

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @beads_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @polecats_topic)
    end

    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:live, live?)
     |> assign(:worker_label, Vernacular.label(:worker))
     |> assign(:rig_label, Vernacular.label(:rig))
     |> assign(:issue_label, Vernacular.label(:issue))
     |> assign(:workspace_label, Vernacular.label(:workspace))
     |> assign(:pr_label, Vernacular.label(:pr))
     |> assign(:merge_queue_label, Vernacular.label(:merge_queue))
     |> assign(:escalation_label, Vernacular.label(:escalation))
     |> refresh_workspaces()
     |> subscribe_messages(live?)
     |> refresh_notifications()
     |> refresh_rigs()
     |> refresh_polecats()
     |> refresh_recent_beads()}
  end

  @impl true
  def handle_info({:bead_lifecycle, _event, _issue}, socket) do
    {:noreply,
     socket
     |> refresh_recent_beads()
     |> refresh_workspaces()}
  end

  def handle_info({:polecat_lifecycle, _event, _snapshot}, socket) do
    {:noreply,
     socket
     |> refresh_polecats()
     |> refresh_workspaces()
     |> refresh_rigs()}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply, refresh_notifications(socket)}
  end

  # ---- data ----

  defp refresh_polecats(socket) do
    polecats =
      try do
        Polecat.list_children()
      rescue
        _ -> []
      end

    workspaces_by_id =
      socket.assigns[:workspaces_by_id] || index_workspaces(load_workspaces())

    polecats =
      Enum.map(polecats, fn p ->
        Map.put(p, :workspace_name, workspace_label(workspaces_by_id, p.workspace_id))
      end)

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

  # ---- notifications ----

  # Subscribe to each known workspace's message topic. Workspaces created
  # after mount won't be picked up until the next full page load — acceptable
  # for a dashboard that's typically left open on a stable set of workspaces.
  defp subscribe_messages(socket, false), do: socket

  defp subscribe_messages(socket, true) do
    (socket.assigns[:workspaces_by_id] || %{})
    |> Map.keys()
    |> Enum.each(&Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(&1)))

    socket
  end

  defp refresh_notifications(socket) do
    notifications =
      try do
        Message.recent_notifications(20)
      rescue
        _ -> []
      end

    assign(socket, :notifications, notifications)
  end

  # ---- workspaces ----

  defp refresh_workspaces(socket) do
    workspaces = load_workspaces()
    issues_by_workspace = group_issues_by_workspace_and_status()
    polecats_by_workspace = group_polecats_by_workspace()

    stats =
      Enum.map(workspaces, fn ws ->
        issue_counts = Map.get(issues_by_workspace, ws.id, %{})

        %{
          id: ws.id,
          name: ws.name,
          prefix: ws.prefix,
          tracker_type: get_in(ws.config || %{}, ["tracker", "type"]) || "none",
          polecats: Map.get(polecats_by_workspace, ws.id, 0),
          open: Map.get(issue_counts, :open, 0),
          in_progress: Map.get(issue_counts, :in_progress, 0),
          closed: Map.get(issue_counts, :closed, 0)
        }
      end)
      |> Enum.sort_by(& &1.name)

    socket
    |> assign(:workspaces, stats)
    |> assign(:workspaces_by_id, index_workspaces(workspaces))
  end

  defp load_workspaces do
    Ash.read!(Workspace)
  rescue
    _ -> []
  end

  defp index_workspaces(workspaces) do
    Map.new(workspaces, fn ws -> {ws.id, ws} end)
  end

  defp workspace_label(_workspaces_by_id, nil), do: "(none)"

  defp workspace_label(workspaces_by_id, ws_id) do
    case Map.fetch(workspaces_by_id, ws_id) do
      {:ok, ws} -> ws.name
      :error -> "(unknown)"
    end
  end

  defp group_issues_by_workspace_and_status do
    Issue
    |> Ash.Query.select([:id, :status, :workspace_id])
    |> Ash.read!()
    |> Enum.reduce(%{}, fn i, acc ->
      Map.update(acc, i.workspace_id, %{i.status => 1}, fn ws_counts ->
        Map.update(ws_counts, i.status, 1, &(&1 + 1))
      end)
    end)
  rescue
    _ -> %{}
  end

  defp group_polecats_by_workspace do
    try do
      Polecat.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      Map.update(acc, p.workspace_id, 1, &(&1 + 1))
    end)
  end

  # ---- rigs ----

  defp refresh_rigs(socket) do
    workspaces = socket.assigns[:workspaces_by_id] |> values_or_load()

    paths_by_rig = collect_rig_paths(workspaces)
    polecats_by_rig = group_polecats_by_rig()

    rigs =
      paths_by_rig
      |> Map.merge(rigs_from_polecats(polecats_by_rig, paths_by_rig))
      |> Enum.map(fn {name, entry} ->
        path = entry.path

        worktree_count =
          case path do
            nil -> 0
            p when is_binary(p) -> safe_worktree_count(p)
          end

        %{
          name: name,
          path: path,
          source: entry.source,
          polecats: Map.get(polecats_by_rig, name, 0),
          worktrees: worktree_count
        }
      end)
      |> Enum.sort_by(& &1.name)

    assign(socket, :rigs, rigs)
  end

  defp values_or_load(nil), do: load_workspaces()
  defp values_or_load(%{} = m), do: Map.values(m)

  # Build {rig_name => %{path:, source:}} from every workspace's
  # config["rig_paths"] plus the application-env fallback. Workspace
  # entries win over app-env when names collide.
  defp collect_rig_paths(workspaces) do
    app_paths =
      :arbiter
      |> Application.get_env(:rig_paths, %{})
      |> Map.new(fn {name, path} -> {name, %{path: path, source: "(app)"}} end)

    workspaces
    |> Enum.reduce(app_paths, fn ws, acc ->
      ws_rig_paths =
        case ws.config do
          %{"rig_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.reduce(ws_rig_paths, acc, fn {name, path}, acc ->
        Map.put(acc, name, %{path: path, source: ws.name})
      end)
    end)
  end

  defp group_polecats_by_rig do
    try do
      Polecat.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      rig = p.rig || "(none)"
      Map.update(acc, rig, 1, &(&1 + 1))
    end)
  end

  # A polecat can be running against a rig name that isn't in any
  # `rig_paths` config (default-rig "unknown", a typo, or an inherited
  # legacy value). Surface those as well so the operator can see them.
  defp rigs_from_polecats(polecats_by_rig, configured) do
    polecats_by_rig
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(configured, &1))
    |> Map.new(fn name -> {name, %{path: nil, source: "(unconfigured)"}} end)
  end

  defp safe_worktree_count(path) do
    Worktree.list(path) |> length()
  rescue
    _ -> 0
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

  defp kind_badge_class(:notification), do: "badge-info"
  defp kind_badge_class(:direction), do: "badge-warning"
  defp kind_badge_class(:flag), do: "badge-accent"
  defp kind_badge_class(_), do: "badge-ghost"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(_), do: ""

  defp excerpt(nil), do: ""

  defp excerpt(body) when is_binary(body) do
    if String.length(body) > 80, do: String.slice(body, 0, 80) <> "…", else: body
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
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

        <section class="card bg-base-200 p-4 mb-6">
          <h2 class="text-lg font-semibold mb-3">
            {String.capitalize(@workspace_label)}s ({length(@workspaces)})
          </h2>
          <%= if @workspaces == [] do %>
            <p class="text-base-content/60 italic">No workspaces.</p>
          <% else %>
            <table class="table table-sm" id="workspaces-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Prefix</th>
                  <th>Tracker</th>
                  <th class="text-right">Active {String.capitalize(@worker_label)}s</th>
                  <th class="text-right">Open</th>
                  <th class="text-right">In&nbsp;progress</th>
                  <th class="text-right">Closed</th>
                </tr>
              </thead>
              <tbody>
                <%= for ws <- @workspaces do %>
                  <tr>
                    <td>{ws.name}</td>
                    <td><code class="text-xs">{ws.prefix}</code></td>
                    <td class="text-xs">{ws.tracker_type}</td>
                    <td class="text-right">{ws.polecats}</td>
                    <td class="text-right">{ws.open}</td>
                    <td class="text-right">{ws.in_progress}</td>
                    <td class="text-right">{ws.closed}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </section>

        <section class="card bg-base-200 p-4 mb-6">
          <h2 class="text-lg font-semibold mb-3">
            {String.capitalize(@rig_label)}s ({length(@rigs)})
          </h2>
          <%= if @rigs == [] do %>
            <p class="text-base-content/60 italic">
              No {@rig_label}s configured. Add entries to <code>:arbiter, :rig_paths</code>
              in config or to a workspace's <code>config["rig_paths"]</code>.
            </p>
          <% else %>
            <table class="table table-sm" id="rigs-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Path</th>
                  <th>Source</th>
                  <th class="text-right">Active {String.capitalize(@worker_label)}s</th>
                  <th class="text-right">Worktrees</th>
                </tr>
              </thead>
              <tbody>
                <%= for rig <- @rigs do %>
                  <tr>
                    <td><code class="text-xs">{rig.name}</code></td>
                    <td class="text-xs text-base-content/80">{rig.path || "(no path)"}</td>
                    <td class="text-xs">{rig.source}</td>
                    <td class="text-right">{rig.polecats}</td>
                    <td class="text-right">{rig.worktrees}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </section>

        <section class="card bg-base-200 p-4 mb-6">
          <h2 class="text-lg font-semibold mb-3">
            Notifications ({length(@notifications)})
          </h2>
          <%= if @notifications == [] do %>
            <p class="text-base-content/60 italic" id="notifications-empty">
              No notifications yet. {String.capitalize(@worker_label)} completions and
              system events appear here in real time.
            </p>
          <% else %>
            <ul class="flex flex-col gap-1" id="notifications-feed">
              <%= for n <- @notifications do %>
                <li class="flex items-baseline gap-2 text-sm border-b border-base-300/40 pb-1">
                  <span class="text-xs text-base-content/50 whitespace-nowrap">
                    {format_ts(n.inserted_at)}
                  </span>
                  <span class={["badge badge-sm", kind_badge_class(n.kind)]}>{n.kind}</span>
                  <%= if n.from_ref do %>
                    <code class="text-xs">{n.from_ref}</code>
                  <% end %>
                  <span class="text-base-content/90">
                    {n.subject || excerpt(n.body)}
                  </span>
                </li>
              <% end %>
            </ul>
          <% end %>
        </section>

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
                    <th>{String.capitalize(@issue_label)}</th>
                    <th>Workspace</th>
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
                      <td class="text-xs">{Map.get(p, :workspace_name) || "(none)"}</td>
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
              Recent {String.capitalize(@issue_label)}s ({length(@recent_beads)})
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
                    <td>
                      <.link navigate={~p"/beads/#{b.id}"} class="link link-hover">
                        <code class="text-xs">{b.id}</code>
                      </.link>
                    </td>
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
            <h2 class="text-lg font-semibold mb-3">{String.capitalize(@pr_label)}s in flight</h2>
            <p class="text-base-content/60 italic" id="prs-empty">
              No {@merge_queue_label}s running. (Phase 4 will register {@merge_queue_label} instances
              per {@workspace_label} and surface their queues here.)
            </p>
          </section>

          <section class="card bg-base-200 p-4">
            <h2 class="text-lg font-semibold mb-3">{String.capitalize(@escalation_label)}s</h2>
            <p class="text-base-content/60 italic" id="escalations-empty">
              No {@escalation_label}s. ({String.capitalize(@escalation_label)} resource is a Phase 5 follow-up.)
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
