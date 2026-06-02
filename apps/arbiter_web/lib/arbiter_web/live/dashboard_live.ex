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
  alias Arbiter.Polecats.Run
  alias Arbiter.Vernacular
  require Ash.Query

  @beads_topic "beads"
  @polecats_topic "polecats"

  # Number of directives shown in the "recent directives" list.
  @recent_beads_limit 20

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @beads_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @polecats_topic)
      # Drives live elapsed counters (active workers) and relative timestamps
      # (notifications). Only reassigns :now — no DB reads in the tick handler.
      :timer.send_interval(1000, self(), :tick)
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
     |> refresh_completed_runs()
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
     |> refresh_completed_runs()
     |> refresh_workspaces()
     |> refresh_rigs()}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply, refresh_notifications(socket)}
  end

  # Lightweight 1s tick: only advances the clock so elapsed counters and
  # relative timestamps stay live. No data reads here.
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
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

  defp refresh_completed_runs(socket) do
    runs =
      try do
        Run
        |> Ash.Query.filter(status in [:completed, :failed])
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(10)
        |> Ash.read!()
      rescue
        _ -> []
      end

    assign(socket, :completed_runs, runs)
  end

  # Non-closed directives surface ahead of closed ones; each group is ordered
  # by updated_at desc. We read each group bounded by the display limit, then
  # concat and take the limit — so active directives are never pushed off the
  # list by more-recently-updated closed ones (the limit applies AFTER the
  # grouped sort, not before).
  defp refresh_recent_beads(socket) do
    active =
      Issue
      |> Ash.Query.filter(status != :closed)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@recent_beads_limit)
      |> Ash.read!()

    closed =
      Issue
      |> Ash.Query.filter(status == :closed)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@recent_beads_limit)
      |> Ash.read!()

    beads = Enum.take(active ++ closed, @recent_beads_limit)

    blocked_counts = blocked_counts_for(Enum.map(beads, & &1.id))

    beads =
      Enum.map(beads, fn b ->
        Map.put(b, :blocked_count, Map.get(blocked_counts, b.id, 0))
      end)

    assign(socket, :recent_beads, beads)
  end

  # For the given bead ids, count how many of each bead's `:depends_on` edges
  # point at a target issue that is NOT yet closed — i.e. how many open
  # blockers gate the bead. One extra Dependency read + one Issue status read
  # scoped to the targets, keyed by the dependent (`from_issue_id`).
  #
  # NOTE (data hook): this only counts `:depends_on` edges. If you later want to
  # also surface inbound `:blocks` edges, add a second pass keyed on
  # `to_issue_id` here — the template already renders whatever count lands in
  # each bead's `:blocked_count`.
  defp blocked_counts_for([]), do: %{}

  defp blocked_counts_for(bead_ids) do
    deps =
      Arbiter.Beads.Dependency
      |> Ash.Query.filter(type == :depends_on and from_issue_id in ^bead_ids)
      |> Ash.Query.select([:from_issue_id, :to_issue_id])
      |> Ash.read!()

    target_ids = deps |> Enum.map(& &1.to_issue_id) |> Enum.uniq()

    closed_targets =
      case target_ids do
        [] ->
          MapSet.new()

        ids ->
          Issue
          |> Ash.Query.filter(id in ^ids and status == :closed)
          |> Ash.Query.select([:id])
          |> Ash.read!()
          |> MapSet.new(& &1.id)
      end

    deps
    |> Enum.reject(&MapSet.member?(closed_targets, &1.to_issue_id))
    |> Enum.reduce(%{}, fn dep, acc ->
      Map.update(acc, dep.from_issue_id, 1, &(&1 + 1))
    end)
  rescue
    _ -> %{}
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

  defp polecat_status_class(:idle), do: "badge-ghost"
  defp polecat_status_class(:running), do: "badge-info"
  defp polecat_status_class(:awaiting), do: "badge-warning"
  defp polecat_status_class(:awaiting_tribunal), do: "badge-warning"
  defp polecat_status_class(:awaiting_review), do: "badge-warning"
  defp polecat_status_class(:completed), do: "badge-success"
  defp polecat_status_class(:failed), do: "badge-error"
  defp polecat_status_class(_), do: ""

  defp polecat_status_label(:idle), do: "Idle"
  defp polecat_status_label(:running), do: "Running"
  defp polecat_status_label(:awaiting), do: "Awaiting"
  defp polecat_status_label(:awaiting_tribunal), do: "In tribunal"
  defp polecat_status_label(:awaiting_review), do: "Awaiting review"
  defp polecat_status_label(:completed), do: "Completed"
  defp polecat_status_label(:failed), do: "Failed"

  defp polecat_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp polecat_status_label(other), do: to_string(other)

  defp run_status_class(:completed), do: "badge-success"
  defp run_status_class(:failed), do: "badge-error"
  defp run_status_class(:running), do: "badge-info"
  defp run_status_class(_), do: "badge-ghost"

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp kind_badge_class(:notification), do: "badge-info"
  defp kind_badge_class(:direction), do: "badge-warning"
  defp kind_badge_class(:flag), do: "badge-accent"
  defp kind_badge_class(_), do: "badge-ghost"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(_), do: ""

  # Compact relative timestamp for the notifications feed. Stays live because
  # the caller passes @now, which the :tick handler advances each second.
  defp relative_time(%DateTime{} = ts, %DateTime{} = now) do
    seconds = DateTime.diff(now, ts, :second) |> max(0)

    cond do
      seconds < 10 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_, _), do: ""

  # An MR/PR ref is not currently persisted on the polecat snapshot, so this
  # degrades to nil. When the dispatch flow starts stashing it in meta (under
  # :mr_ref or "mr_ref"), the awaiting-review link lights up automatically.
  defp mr_ref(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :mr_ref) || Map.get(meta, "mr_ref")
  end

  defp mr_ref(_), do: nil

  # Ordered worker lifecycle for the inline step indicator. :failed is handled
  # separately in the template (it doesn't belong on the happy-path track).
  @polecat_flow [:idle, :running, :awaiting, :completed]

  defp polecat_flow, do: @polecat_flow

  # Returns :done | :current | :todo for a step relative to the worker's
  # current status, so the template can color the inline step track.
  defp flow_state(step, status) do
    step_idx = Enum.find_index(@polecat_flow, &(&1 == step))
    status_idx = Enum.find_index(@polecat_flow, &(&1 == status))

    cond do
      is_nil(step_idx) or is_nil(status_idx) -> :todo
      step_idx < status_idx -> :done
      step_idx == status_idx -> :current
      true -> :todo
    end
  end

  defp excerpt(nil), do: ""

  defp excerpt(body) when is_binary(body) do
    if String.length(body) > 80, do: String.slice(body, 0, 80) <> "…", else: body
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Dashboard</h1>
            <p class="text-sm text-base-content/60">
              Operational view of active work across every {@workspace_label}.
            </p>
          </div>
          <span
            id="live-indicator"
            class={[
              "badge badge-sm gap-1.5 transition-colors duration-200",
              if(@live, do: "badge-success", else: "badge-warning")
            ]}
            title={
              if @live,
                do: "WebSocket connected — updates arrive in real time",
                else: "Static render — refresh the page to reconnect"
            }
          >
            <%= if @live do %>
              <span class="relative flex h-2 w-2">
                <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success-content opacity-75">
                </span>
                <span class="relative inline-flex h-2 w-2 rounded-full bg-success-content"></span>
              </span>
              live
            <% else %>
              <.icon name="hero-exclamation-triangle" class="size-3" /> stale (refresh)
            <% end %>
          </span>
        </div>

        <%!-- ── A. Stats bar ─────────────────────────────────────────── --%>
        <div class="stats stats-vertical lg:stats-horizontal w-full shadow bg-base-200 border border-base-300">
          <div class="stat">
            <div class="stat-figure text-success">
              <.icon name="hero-inbox-stack" class="size-7" />
            </div>
            <div class="stat-title">Open {cap_plural(@issue_label)}</div>
            <div class="stat-value text-success">{open_issue_total(@workspaces)}</div>
            <div class="stat-desc">across {length(@workspaces)} {plural(@workspace_label)}</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-info">
              <.icon name="hero-cpu-chip" class="size-7" />
            </div>
            <div class="stat-title">Active {cap_plural(@worker_label)}</div>
            <div class="stat-value text-info">{length(@polecats)}</div>
            <div class="stat-desc">running right now</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-base-content/70">
              <.icon name="hero-building-office-2" class="size-7" />
            </div>
            <div class="stat-title">{cap_plural(@workspace_label)}</div>
            <div class="stat-value">{length(@workspaces)}</div>
            <div class="stat-desc">configured</div>
          </div>

          <%!-- Placeholder slot. Activates when the Admiral inbox campaign lands
               and exposes an unread-count backing source. --%>
          <div class="stat opacity-50">
            <div class="stat-figure text-base-content/40">
              <.icon name="hero-envelope" class="size-7" />
            </div>
            <div class="stat-title">Admiral Inbox</div>
            <div class="stat-value text-base-content/40">—</div>
            <div class="stat-desc">coming soon</div>
          </div>
        </div>

        <%!-- ── B + C. Active workers / Directive queue ──────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Active workers --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <div class="flex items-center justify-between">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-bolt" class="size-5 text-info" />
                  Active {cap_plural(@worker_label)} ({length(@polecats)})
                </h2>
              </div>

              <div
                :if={@polecats == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon name="hero-moon" class="size-8 mx-auto text-base-content/30" />
                <p class="mt-2 text-sm font-medium text-base-content/70">
                  No active {plural(@worker_label)}.
                </p>
                <p class="text-xs text-base-content/50">
                  Dispatched {plural(@worker_label)} appear here with live step progress
                  and elapsed time the moment work begins.
                </p>
              </div>

              <ul :if={@polecats != []} id="active-polecats" class="flex flex-col gap-3">
                <li
                  :for={p <- @polecats}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-info/50"
                >
                  <div class="flex items-center justify-between gap-2">
                    <.link
                      navigate={~p"/polecats/#{p.bead_id}"}
                      class="flex items-center gap-2 min-w-0 group"
                    >
                      <span class="relative flex h-2.5 w-2.5 shrink-0">
                        <span
                          :if={p.status == :running}
                          class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-75"
                        >
                        </span>
                        <span class={[
                          "relative inline-flex h-2.5 w-2.5 rounded-full",
                          status_dot_class(p.status)
                        ]}>
                        </span>
                      </span>
                      <code class="text-xs font-semibold group-hover:text-info transition-colors truncate">
                        {p.bead_id}
                      </code>
                    </.link>
                    <span class="text-xs font-mono text-base-content/70 tabular-nums shrink-0">
                      {humanize_seconds(runtime_seconds(p.started_at, @now))}
                    </span>
                  </div>

                  <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                    <span class="truncate">{Map.get(p, :workspace_name) || "(none)"}</span>
                    <span class="badge badge-ghost badge-sm font-mono">{p.current_step}</span>
                  </div>

                  <%!-- Inline lifecycle track: idle → running → awaiting → completed --%>
                  <div class="flex items-center gap-1 mt-2.5">
                    <span
                      :for={step <- polecat_flow()}
                      class="flex items-center gap-1 flex-1 last:flex-none"
                    >
                      <span
                        class={[
                          "h-1.5 flex-1 rounded-full transition-colors duration-300",
                          flow_bar_class(flow_state(step, p.status))
                        ]}
                        title={polecat_status_label(step)}
                      >
                      </span>
                    </span>
                    <span class={["badge badge-sm ml-1 shrink-0", polecat_status_class(p.status)]}>
                      {polecat_status_label(p.status)}
                    </span>
                  </div>

                  <div
                    :if={p.status == :awaiting and mr_ref(p)}
                    class="mt-2 flex items-center gap-1 text-xs"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3 text-warning" />
                    <code class="text-warning">{mr_ref(p)}</code>
                  </div>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Directive queue --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-queue-list" class="size-5 text-base-content/70" />
                Recent {cap_plural(@issue_label)} ({length(@recent_beads)})
              </h2>

              <div
                :if={@recent_beads == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon
                  name="hero-clipboard-document-list"
                  class="size-8 mx-auto text-base-content/30"
                />
                <p class="mt-2 text-sm text-base-content/60">
                  No {plural(@issue_label)} yet. New and updated {plural(@issue_label)} surface here.
                </p>
              </div>

              <ul :if={@recent_beads != []} id="recent-beads" class="flex flex-col gap-1.5">
                <li
                  :for={b <- @recent_beads}
                  class={[
                    "rounded-box border bg-base-100 px-3 py-2 transition-colors duration-150 hover:bg-base-300/40",
                    if(b.priority == 1,
                      do: "border-l-4 border-error bg-error/5",
                      else: "border-base-300"
                    )
                  ]}
                >
                  <div class="flex items-center gap-2">
                    <span class={[
                      "badge badge-sm font-mono shrink-0",
                      if(b.priority == 1, do: "badge-error", else: "badge-ghost")
                    ]}>
                      P{b.priority}
                    </span>
                    <.link navigate={~p"/beads/#{b.id}"} class="min-w-0 flex-1 group">
                      <div class="flex items-center gap-2">
                        <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
                          {b.id}
                        </code>
                        <span
                          class="truncate text-sm group-hover:text-primary transition-colors"
                          title={b.title}
                        >
                          {b.title}
                        </span>
                      </div>
                    </.link>
                    <span
                      :if={Map.get(b, :blocked_count, 0) > 0}
                      class="badge badge-warning badge-sm gap-1 shrink-0"
                      title="Open blockers gating this directive"
                    >
                      <.icon name="hero-lock-closed" class="size-3" />
                      {Map.get(b, :blocked_count)} blocked
                    </span>
                    <span class={["badge badge-sm shrink-0", status_badge_class(b.status)]}>
                      {b.status}
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <%!-- ── D. Notifications feed ────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-bell-alert" class="size-5 text-base-content/70" />
              Notifications ({length(@notifications)})
            </h2>

            <div
              :if={@notifications == []}
              id="notifications-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-bell-slash" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No notifications yet. {String.capitalize(@worker_label)} completions and
                system events appear here in real time.
              </p>
            </div>

            <ul
              :if={@notifications != []}
              id="notifications-feed"
              class="flex flex-col gap-2 max-h-80 overflow-y-auto pr-1"
            >
              <li
                :for={n <- @notifications}
                class={[
                  "flex items-start gap-3 rounded-box bg-base-100 border-l-4 px-3 py-2",
                  kind_border_class(n.kind)
                ]}
              >
                <span class={["badge badge-sm shrink-0 mt-0.5", kind_badge_class(n.kind)]}>
                  {n.kind}
                </span>
                <div class="min-w-0 flex-1">
                  <div class="flex items-baseline gap-2">
                    <span class="text-sm text-base-content/90 truncate">
                      {n.subject || excerpt(n.body)}
                    </span>
                    <code :if={n.from_ref} class="text-xs text-base-content/50 shrink-0">
                      {n.from_ref}
                    </code>
                  </div>
                </div>
                <span
                  class="text-xs text-base-content/50 whitespace-nowrap shrink-0"
                  title={format_ts(n.inserted_at)}
                >
                  {relative_time(n.inserted_at, @now)}
                </span>
              </li>
            </ul>
          </div>
        </section>

        <%!-- ── E. Workspaces / Warships as compact cards ────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section id="workspaces-section" class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-building-office-2" class="size-5 text-base-content/70" />
                {cap_plural(@workspace_label)} ({length(@workspaces)})
              </h2>

              <p :if={@workspaces == []} class="text-sm text-base-content/60 italic">
                No {plural(@workspace_label)} configured yet.
              </p>

              <div :if={@workspaces != []} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div
                  :for={ws <- @workspaces}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-primary/40"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="font-medium truncate" title={ws.name}>{ws.name}</span>
                    <code class="badge badge-ghost badge-sm font-mono shrink-0">{ws.prefix}</code>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">tracker: {ws.tracker_type}</div>
                  <div class="flex flex-wrap items-center gap-1.5 mt-2.5 text-xs">
                    <span class="badge badge-sm badge-info" title={"Active #{plural(@worker_label)}"}>
                      <.icon name="hero-cpu-chip" class="size-3 mr-0.5" />{ws.polecats}
                    </span>
                    <span class="badge badge-sm badge-success" title={"Open #{plural(@issue_label)}"}>
                      {ws.open} open
                    </span>
                    <span class="badge badge-sm badge-ghost" title="In progress">
                      {ws.in_progress} active
                    </span>
                    <span class="badge badge-sm badge-ghost" title="Closed">{ws.closed} closed</span>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section id="rigs-section" class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-server-stack" class="size-5 text-base-content/70" />
                {cap_plural(@rig_label)} ({length(@rigs)})
              </h2>

              <p :if={@rigs == []} class="text-sm text-base-content/60 italic">
                No {plural(@rig_label)} configured. Add entries to
                <code class="text-xs">:arbiter, :rig_paths</code>
                in config or to a {@workspace_label}'s <code class="text-xs">config["rig_paths"]</code>.
              </p>

              <div :if={@rigs != []} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div
                  :for={rig <- @rigs}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-secondary/40"
                >
                  <div class="flex items-center justify-between gap-2">
                    <code class="font-medium truncate" title={rig.name}>{rig.name}</code>
                    <span class="badge badge-ghost badge-sm shrink-0">{rig.source}</span>
                  </div>
                  <div
                    class="text-xs text-base-content/50 mt-0.5 truncate font-mono"
                    title={rig.path || "(no path)"}
                  >
                    {rig.path || "(no path)"}
                  </div>
                  <div class="flex flex-wrap items-center gap-1.5 mt-2.5 text-xs">
                    <span class="badge badge-sm badge-info" title={"Active #{plural(@worker_label)}"}>
                      <.icon name="hero-cpu-chip" class="size-3 mr-0.5" />{rig.polecats}
                    </span>
                    <span class="badge badge-sm badge-ghost" title="Worktrees">
                      {rig.worktrees} worktrees
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        <%!-- ── G. Completed workers ─────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-check-circle" class="size-5 text-base-content/70" />
              Completed {cap_plural(@worker_label)} ({length(@completed_runs)})
            </h2>

            <div
              :if={@completed_runs == []}
              id="completed-runs-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-archive-box" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No completed {plural(@worker_label)} yet. Past runs appear here after the {@worker_label} finishes or fails.
              </p>
            </div>

            <div :if={@completed_runs != []} class="overflow-x-auto">
              <table class="table table-sm" id="completed-runs">
                <thead>
                  <tr class="text-base-content/60">
                    <th>{String.capitalize(@issue_label)}</th>
                    <th>Title</th>
                    <th>Status</th>
                    <th>Started</th>
                    <th class="text-right">Duration</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={r <- @completed_runs} class="hover:bg-base-300/40 transition-colors">
                    <td>
                      <.link navigate={~p"/polecats/history/#{r.id}"} class="link link-hover">
                        <code class="text-xs">{r.bead_id}</code>
                      </.link>
                    </td>
                    <td class="text-xs max-w-xs truncate" title={r.bead_title || ""}>
                      {r.bead_title || "—"}
                    </td>
                    <td>
                      <span class={["badge badge-sm", run_status_class(r.status)]}>{r.status}</span>
                    </td>
                    <td class="text-xs whitespace-nowrap">{format_ts(r.started_at)}</td>
                    <td class="text-xs text-right font-mono tabular-nums whitespace-nowrap">
                      {humanize_duration(r.started_at, r.completed_at)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <%!-- ── F. Coming-soon placeholders ──────────────────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section class="card bg-base-200/60 border border-dashed border-base-300">
            <div class="card-body p-4 gap-2">
              <h2 class="text-lg font-semibold flex items-center gap-2 text-base-content/70">
                <.icon name="hero-paper-airplane" class="size-5" />
                {cap_plural(@pr_label)} in flight <span class="badge badge-ghost badge-sm">soon</span>
              </h2>
              <p class="text-sm text-base-content/50" id="prs-empty">
                No {plural(@merge_queue_label)} running. (Phase 4 will register {@merge_queue_label} instances
                per {@workspace_label} and surface their queues here.)
              </p>
            </div>
          </section>

          <section class="card bg-base-200/60 border border-dashed border-base-300">
            <div class="card-body p-4 gap-2">
              <h2 class="text-lg font-semibold flex items-center gap-2 text-base-content/70">
                <.icon name="hero-exclamation-triangle" class="size-5" />
                {cap_plural(@escalation_label)}
                <span class="badge badge-ghost badge-sm">soon</span>
              </h2>
              <p class="text-sm text-base-content/50" id="escalations-empty">
                No {plural(@escalation_label)}. ({String.capitalize(@escalation_label)} resource is a Phase 5 follow-up.)
              </p>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers (labels + stats + status visuals) ----

  # English pluralization for vernacular labels so headers read naturally
  # regardless of the configured vocabulary ("refinery" → "refineries",
  # "watch" → "watches", "bead" → "beads"). Naive `label <> "s"` breaks on
  # trailing -y and sibilant endings, which a polished surface shouldn't show.
  defp pluralize(word) when is_binary(word) do
    cond do
      String.ends_with?(word, ~w(s x z ch sh)) -> word <> "es"
      Regex.match?(~r/[^aeiou]y$/u, word) -> String.replace_suffix(word, "y", "ies")
      true -> word <> "s"
    end
  end

  # Pluralize a label, preserving its configured case (for inline prose).
  defp plural(label), do: pluralize(label)

  # Capitalize then pluralize a label (for section headers / stat titles).
  defp cap_plural(label), do: label |> String.capitalize() |> pluralize()

  defp open_issue_total(workspaces) do
    Enum.reduce(workspaces, 0, fn ws, acc -> acc + Map.get(ws, :open, 0) end)
  end

  # Solid status dot color for the active-worker rows (mirrors the badge palette).
  defp status_dot_class(:running), do: "bg-info"
  defp status_dot_class(:awaiting), do: "bg-warning"
  defp status_dot_class(:completed), do: "bg-success"
  defp status_dot_class(:failed), do: "bg-error"
  defp status_dot_class(_), do: "bg-base-content/30"

  # Inline lifecycle-track segment color, given a step's state vs current status.
  defp flow_bar_class(:done), do: "bg-success"
  defp flow_bar_class(:current), do: "bg-info"
  defp flow_bar_class(:todo), do: "bg-base-300"

  # Left-accent border per notification kind, matching kind_badge_class/1.
  defp kind_border_class(:notification), do: "border-info"
  defp kind_border_class(:direction), do: "border-warning"
  defp kind_border_class(:flag), do: "border-accent"
  defp kind_border_class(_), do: "border-base-300"
end
