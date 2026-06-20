defmodule ArbiterWeb.TaskDetailLive do
  @moduledoc """
  Per-task detail view at `/tasks/:id` — combines the resource record,
  any active worker, dependency edges, and recent audit-log versions
  into one page. Re-renders on `:task_lifecycle` and `:worker_lifecycle`
  events so the page stays current.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Version
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  require Ash.Query

  @tasks_topic "tasks"
  @workers_topic "workers"

  @impl true
  def mount(%{"id" => task_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
    end

    {:ok,
     socket
     |> assign(:task_id, task_id)
     |> assign(:live, connected?(socket))
     |> assign(:issue_label, "issue")
     |> assign(:worker_label, "worker")
     |> assign(:workspace_label, "workspace")
     |> assign(:rig_label, "repo")
     |> refresh_all()}
  end

  @impl true
  def handle_info({:task_lifecycle, _event, %{id: id}}, %{assigns: %{task_id: id}} = socket) do
    {:noreply, refresh_all(socket)}
  end

  # Lifecycle events for other tasks can still affect this page's
  # dependency section (status of a target changed), so refresh on any.
  def handle_info({:task_lifecycle, _event, _other}, socket) do
    {:noreply, refresh_deps(socket)}
  end

  def handle_info(
        {:worker_lifecycle, _event, %{task_id: id}},
        %{assigns: %{task_id: id}} = socket
      ) do
    {:noreply, refresh_worker(socket)}
  end

  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  # ---- data ----

  defp refresh_all(socket) do
    socket
    |> refresh_task()
    |> refresh_workspace()
    |> refresh_worker()
    |> refresh_deps()
    |> refresh_versions()
  end

  defp refresh_task(socket) do
    case Ash.get(Issue, socket.assigns.task_id) do
      {:ok, task} -> assign(socket, :task, task)
      {:error, _} -> assign(socket, :task, nil)
    end
  end

  defp refresh_workspace(%{assigns: %{task: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  defp refresh_worker(socket) do
    snap =
      case Worker.whereis(socket.assigns.task_id) do
        nil -> nil
        pid -> safe_state(pid)
      end

    assign(socket, :worker, snap)
  end

  defp safe_state(pid) do
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp refresh_deps(socket) do
    id = socket.assigns.task_id

    {outbound, inbound} =
      try do
        all =
          Dependency
          |> Ash.Query.filter(from_issue_id == ^id or to_issue_id == ^id)
          |> Ash.read!()

        out = Enum.filter(all, &(&1.from_issue_id == id))
        ins = Enum.filter(all, &(&1.to_issue_id == id))

        # Look up the other-side issue for each row so the template can
        # show the target's title + status without an extra request per
        # edge.
        other_ids =
          (Enum.map(out, & &1.to_issue_id) ++ Enum.map(ins, & &1.from_issue_id))
          |> Enum.uniq()

        by_id =
          other_ids
          |> Enum.map(fn oid ->
            case Ash.get(Issue, oid) do
              {:ok, b} -> {oid, b}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {decorate(out, :to_issue_id, by_id), decorate(ins, :from_issue_id, by_id)}
      rescue
        _ -> {[], []}
      end

    socket
    |> assign(:outbound_deps, outbound)
    |> assign(:inbound_deps, inbound)
  end

  defp decorate(deps, side_key, by_id) do
    Enum.map(deps, fn d ->
      other = Map.get(by_id, Map.get(d, side_key))
      Map.put(d, :other_issue, other)
    end)
  end

  defp refresh_versions(socket) do
    versions =
      try do
        Version
        |> Ash.Query.filter(version_source_id == ^socket.assigns.task_id)
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.Query.limit(20)
        |> Ash.read!()
      rescue
        _ -> []
      end

    assign(socket, :versions, versions)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-sm text-base-content/60">
              <.icon name="hero-clipboard-document-list" class="size-4" />
              <span>{String.capitalize(@issue_label)}</span>
              <code class="text-base-content/80">{@task_id}</code>
            </div>
            <h1 :if={@task} class="text-2xl font-bold tracking-tight mt-1">
              <span class="min-w-0 truncate" title={@task.title}>{@task.title}</span>
            </h1>
            <h1 :if={!@task} class="text-2xl font-bold tracking-tight mt-1">
              {String.capitalize(@issue_label)} not found
            </h1>
            <div :if={@task} class="flex flex-wrap items-center gap-2 mt-2">
              <span class={["badge", status_badge_class(@task.status)]}>
                {@task.status}
              </span>
              <span
                class={[
                  "badge font-mono gap-1",
                  if(@task.priority == 1, do: "badge-error", else: "badge-ghost")
                ]}
                title={"Priority #{@task.priority}"}
              >
                <.icon :if={@task.priority == 1} name="hero-exclamation-triangle" class="size-3" />
                P{@task.priority}
              </span>
              <span class="badge badge-ghost gap-1">
                <.icon name="hero-tag" class="size-3" />{@task.issue_type}
              </span>
            </div>
          </div>

          <span
            id="live-indicator"
            class={[
              "badge badge-sm gap-1.5 transition-colors duration-200 shrink-0",
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

        <%= if @task do %>
          <%!-- ── A. Record + Worker ─────────────────────────────────── --%>
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Record --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm lg:col-span-2">
              <div class="card-body p-4 gap-4">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-document-text" class="size-5 text-base-content/70" />
                  {String.capitalize(@issue_label)} record
                </h2>

                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
                  <dt class="font-medium text-base-content/60">Status</dt>
                  <dd>
                    <span class={["badge badge-sm", status_badge_class(@task.status)]}>
                      {@task.status}
                    </span>
                  </dd>

                  <dt class="font-medium text-base-content/60">Priority</dt>
                  <dd>
                    <span class={[
                      "badge badge-sm font-mono",
                      if(@task.priority == 1, do: "badge-error", else: "badge-ghost")
                    ]}>
                      P{@task.priority}
                    </span>
                  </dd>

                  <dt class="font-medium text-base-content/60">Difficulty</dt>
                  <dd>
                    <span class={[
                      "badge badge-sm font-mono",
                      difficulty_badge_class(@task.difficulty)
                    ]}>
                      {difficulty_label(@task.difficulty)}
                    </span>
                  </dd>

                  <dt class="font-medium text-base-content/60">Type</dt>
                  <dd>{@task.issue_type}</dd>

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

                  <%= if @task.tracker_type != :none do %>
                    <dt class="font-medium text-base-content/60">Tracker</dt>
                    <dd>
                      <span class="badge badge-ghost badge-sm">{@task.tracker_type}</span>
                      <code class="text-xs text-base-content/70 ml-1">{@task.tracker_ref}</code>
                    </dd>
                  <% end %>

                  <%= if @task.assignee do %>
                    <dt class="font-medium text-base-content/60">Assignee</dt>
                    <dd class="flex items-center gap-1.5">
                      <.icon name="hero-user-circle" class="size-4 text-base-content/50" />
                      {@task.assignee}
                    </dd>
                  <% end %>
                </dl>

                <div :if={@task.description} class="space-y-1">
                  <h3 class="text-sm font-medium text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-bars-3-bottom-left" class="size-4" /> Description
                  </h3>
                  <pre class="whitespace-pre-wrap text-xs bg-base-100 border border-base-300 p-3 rounded-box font-mono text-base-content/80">{@task.description}</pre>
                </div>

                <div :if={@task.acceptance} class="space-y-1">
                  <h3 class="text-sm font-medium text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-check-badge" class="size-4" /> Acceptance
                  </h3>
                  <pre class="whitespace-pre-wrap text-xs bg-base-100 border border-base-300 p-3 rounded-box font-mono text-base-content/80">{@task.acceptance}</pre>
                </div>
              </div>
            </section>

            <%!-- Worker (linked worker) --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-4">
                <div class="flex items-center justify-between gap-2">
                  <h2 class="text-lg font-semibold flex items-center gap-2">
                    <.icon name="hero-cpu-chip" class="size-5 text-info" />
                    {String.capitalize(@worker_label)}
                  </h2>
                  <.link
                    :if={@worker}
                    navigate={~p"/workers/#{@task_id}"}
                    class="link link-hover text-sm text-info flex items-center gap-1"
                  >
                    view full output <.icon name="hero-arrow-right" class="size-3" />
                  </.link>
                </div>

                <%= if @worker do %>
                  <div class="rounded-box bg-base-100 border border-base-300 p-3 flex flex-col gap-3">
                    <div class="flex items-center justify-between gap-2">
                      <span class="flex items-center gap-2">
                        <span class="relative flex h-2.5 w-2.5 shrink-0">
                          <span
                            :if={@worker.status == :running}
                            class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-75"
                          >
                          </span>
                          <span class={[
                            "relative inline-flex h-2.5 w-2.5 rounded-full",
                            status_dot_class(@worker.status)
                          ]}>
                          </span>
                        </span>
                        <span class={["badge badge-sm", worker_status_class(@worker.status)]}>
                          {@worker.status}
                        </span>
                      </span>
                      <%= cond do %>
                        <% Map.get(@worker, :claude_session?) && @worker.status in [:idle, :running] -> %>
                          <span class="badge badge-primary badge-sm">
                            {worker_activity_label(@worker)}
                          </span>
                        <% Map.get(@worker, :claude_session?) -> %>
                          <%!-- Run over: the adjacent status badge already says
                               what happened; don't show a frozen activity. --%>
                        <% true -> %>
                          <span class="badge badge-ghost badge-sm font-mono">
                            {@worker.current_step}
                          </span>
                      <% end %>
                    </div>
                    <div class="flex items-center gap-1.5 text-xs text-base-content/60">
                      <.icon name="hero-clock" class="size-3.5" />
                      <span>started {format_started(@worker.started_at)}</span>
                    </div>
                  </div>
                <% else %>
                  <div class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center">
                    <.icon name="hero-moon" class="size-8 mx-auto text-base-content/30" />
                    <p class="mt-2 text-sm font-medium text-base-content/70">
                      No {@worker_label} running for this {@issue_label}.
                    </p>
                    <p class="mt-1 text-xs text-base-content/50">
                      Spawn one with <code class="text-xs bg-base-300 px-1.5 py-0.5 rounded">
                        arb dispatch {@task_id}
                      </code>.
                    </p>
                  </div>
                <% end %>
              </div>
            </section>
          </div>

          <%!-- ── B. Dependency graph ─────────────────────────────────── --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <%!-- Blocked by (outbound :depends_on) --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-4">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="size-5 text-warning" />
                  Blocked by ({length(@outbound_deps)})
                </h2>

                <p
                  :if={@outbound_deps == []}
                  class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-4 text-sm text-center text-base-content/50"
                >
                  No outgoing dependencies.
                </p>

                <ul :if={@outbound_deps != []} class="flex flex-col gap-2">
                  <li
                    :for={d <- @outbound_deps}
                    class="rounded-box bg-base-100 border border-base-300 p-2.5 transition-colors duration-150 hover:border-warning/50"
                  >
                    <.dep_edge dep={d} other_id={d.to_issue_id} direction={:upstream} />
                  </li>
                </ul>
              </div>
            </section>

            <%!-- Blocks (inbound) --%>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-4">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-arrow-trending-up" class="size-5 text-base-content/70" />
                  Blocks ({length(@inbound_deps)})
                </h2>

                <p
                  :if={@inbound_deps == []}
                  class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-4 text-sm text-center text-base-content/50"
                >
                  Nothing depends on this {@issue_label}.
                </p>

                <ul :if={@inbound_deps != []} class="flex flex-col gap-2">
                  <li
                    :for={d <- @inbound_deps}
                    class="rounded-box bg-base-100 border border-base-300 p-2.5 transition-colors duration-150 hover:border-primary/40"
                  >
                    <.dep_edge dep={d} other_id={d.from_issue_id} direction={:downstream} />
                  </li>
                </ul>
              </div>
            </section>
          </div>

          <%!-- ── C. Audit trail timeline ─────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-clock" class="size-5 text-base-content/70" />
                History ({length(@versions)})
              </h2>

              <p
                :if={@versions == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-sm text-center text-base-content/50"
              >
                No history recorded yet. State transitions for this {@issue_label} appear here.
              </p>

              <ol :if={@versions != []} class="relative flex flex-col">
                <li :for={v <- @versions} class="relative flex gap-3 pb-4 last:pb-0 pl-1">
                  <%!-- timeline rail + node --%>
                  <div class="relative flex flex-col items-center shrink-0">
                    <span class={[
                      "z-10 flex items-center justify-center size-7 rounded-full ring-4 ring-base-200",
                      action_dot_class(v.version_action_name)
                    ]}>
                      <.icon name={action_icon(v.version_action_name)} class="size-4" />
                    </span>
                    <span class="absolute top-7 bottom-0 w-px bg-base-300"></span>
                  </div>

                  <div class="min-w-0 flex-1 -mt-0.5">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={action_badge_class(v.version_action_name)}>
                        {v.version_action_name}
                      </span>
                      <span class="text-xs text-base-content/50 font-mono tabular-nums">
                        {format_audit_ts(v.version_inserted_at)}
                      </span>
                    </div>
                    <p
                      :if={format_changes(v.changes) != ""}
                      class="mt-1 text-xs text-base-content/70 font-mono break-words"
                    >
                      {format_changes(v.changes)}
                    </p>
                  </div>
                </li>
              </ol>
            </div>
          </section>
        <% else %>
          <%!-- ── Not found ───────────────────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-8 items-center text-center gap-2">
              <.icon name="hero-question-mark-circle" class="size-12 text-base-content/30" />
              <p class="text-base-content/70">
                Task <code class="text-sm">{@task_id}</code> not found.
              </p>
            </div>
          </section>
        <% end %>

        <div>
          <.link navigate={~p"/"} class="link link-hover text-sm flex items-center gap-1 w-fit">
            <.icon name="hero-arrow-left" class="size-4" /> Back to dashboard
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- render helpers ----

  attr(:dep, :map, required: true)
  attr(:other_id, :string, required: true)
  attr(:direction, :atom, required: true)

  defp dep_edge(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon
        name={if @direction == :upstream, do: "hero-arrow-up-right", else: "hero-arrow-down-left"}
        class="size-4 text-base-content/40 shrink-0"
      />
      <span class="badge badge-ghost badge-sm font-mono shrink-0">{@dep.type}</span>
      <.link navigate={~p"/tasks/#{@other_id}"} class="min-w-0 flex-1 group">
        <div class="flex items-center gap-2">
          <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
            {@other_id}
          </code>
          <span
            :if={@dep.other_issue}
            class="truncate text-sm group-hover:text-primary transition-colors"
            title={@dep.other_issue.title}
          >
            {@dep.other_issue.title}
          </span>
        </div>
      </.link>
      <span
        :if={@dep.other_issue}
        class={["badge badge-xs shrink-0", status_badge_class(@dep.other_issue.status)]}
      >
        {@dep.other_issue.status}
      </span>
    </div>
    """
  end

  # ---- view helpers (status visuals + formatting) ----

  # Canonical directive-status mapping (matches dashboard + doctrine).
  defp status_badge_class(:open), do: "badge-success"
  defp status_badge_class(:in_progress), do: "badge-info"
  defp status_badge_class(:closed), do: "badge-ghost"
  defp status_badge_class(_), do: ""

  defp worker_status_class(:idle), do: "badge-ghost"
  defp worker_status_class(:running), do: "badge-info"
  defp worker_status_class(:awaiting), do: "badge-warning"
  defp worker_status_class(:completed), do: "badge-success"
  defp worker_status_class(:failed), do: "badge-error"
  defp worker_status_class(_), do: ""

  # Solid status dot color for the linked-worker panel (mirrors the badge palette).
  defp status_dot_class(:running), do: "bg-info"
  defp status_dot_class(:awaiting), do: "bg-warning"
  defp status_dot_class(:completed), do: "bg-success"
  defp status_dot_class(:failed), do: "bg-error"
  defp status_dot_class(_), do: "bg-base-content/30"

  defp difficulty_label(nil), do: "—"
  defp difficulty_label(d) when is_integer(d) and d in 0..4, do: "D#{d}"
  defp difficulty_label(_), do: "—"

  defp difficulty_badge_class(nil), do: "badge-ghost"
  defp difficulty_badge_class(0), do: "badge-success"
  defp difficulty_badge_class(1), do: "badge-info"
  defp difficulty_badge_class(2), do: "badge-secondary"
  defp difficulty_badge_class(3), do: "badge-warning"
  defp difficulty_badge_class(4), do: "badge-error"
  defp difficulty_badge_class(_), do: "badge-ghost"

  # Canonical audit-action mapping (matches AuditLogLive + doctrine).
  defp action_badge_class(:create), do: "badge badge-success"
  defp action_badge_class(:close), do: "badge badge-neutral"
  defp action_badge_class(:reopen), do: "badge badge-warning"
  defp action_badge_class(_), do: "badge badge-info"

  # Filled timeline-node color per audit action (mirrors action_badge_class/1).
  defp action_dot_class(:create), do: "bg-success text-success-content"
  defp action_dot_class(:close), do: "bg-neutral text-neutral-content"
  defp action_dot_class(:reopen), do: "bg-warning text-warning-content"
  defp action_dot_class(_), do: "bg-info text-info-content"

  defp action_icon(:create), do: "hero-plus-circle"
  defp action_icon(:close), do: "hero-lock-closed"
  defp action_icon(:reopen), do: "hero-arrow-path"
  defp action_icon(_), do: "hero-pencil-square"

  # Compact changeset summary for the timeline. Mirrors AuditLogLive.
  defp format_changes(changes) when is_map(changes) do
    changes
    |> Map.take(["status", "title", "priority", "tracker_type", "assignee"])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp format_changes(_), do: ""

  defp format_audit_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_audit_ts(other), do: to_string(other)

  defp format_started(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_started(other), do: to_string(other)

  defp worker_activity_label(worker) do
    case Map.get(worker, :meta) do
      %{"activity" => %{"label" => label}} when is_binary(label) -> label
      %{activity: %{label: label}} when is_binary(label) -> label
      %{"activity" => label} when is_binary(label) -> label
      %{activity: label} when is_binary(label) -> label
      _ -> "working"
    end
  end
end
