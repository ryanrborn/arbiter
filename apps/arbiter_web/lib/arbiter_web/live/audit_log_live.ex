defmodule ArbiterWeb.AuditLogLive do
  @moduledoc """
  LiveView at `/audit` — timeline of task state transitions sourced from
  `AshPaperTrail` versions on `Arbiter.Tasks.Issue`.

  ## What's in scope (MVP)

  Every paper-trail `Version` row for an Issue:
    - create
    - update
    - close
    - reopen

  Filters:
    - **Date range** (`since` / `until` — ISO date strings, both inclusive).
    - **Entity ID** (task id; partial match against `version_source_id`).
    - **Action name** (create | update | close | reopen | all).

  ## What's NOT in scope (Phase 5)

    - Actor filter (paper_trail's default config doesn't track who; needs
      `belongs_to_actor :user, User` setup or a sidecar audit table).
    - Worker lifecycle events (no audit resource yet).
    - PR/merge events (gte-022/023 don't write to paper_trail).

  The acceptance criterion's "filter by actor=coordinator" is therefore
  approximated: the JSON `version_action_inputs` map sometimes contains
  task fields with author names (e.g. assignee). MVP punts on this; once
  `belongs_to_actor` is wired (a separate Phase 5 task), the filter form
  here will be extended.

  ## Export

  "Export as JSON" downloads the currently-filtered version list as a
  JSON-array file via a redirect to `GET /audit/export`.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue.Version
  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filters, default_filters())
     |> load_versions()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> load_versions()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, default_filters())
     |> load_versions()}
  end

  def handle_event("export", _params, socket) do
    payload = versions_to_export(socket.assigns.versions)
    filename = "audit-#{Date.utc_today() |> Date.to_iso8601()}.json"

    {:noreply,
     push_event(socket, "download", %{
       filename: filename,
       content: Jason.encode!(payload, pretty: true),
       content_type: "application/json"
     })}
  end

  # ---- data ----

  defp default_filters do
    %{
      since: nil,
      until: nil,
      entity_id: "",
      action: "all"
    }
  end

  defp parse_filters(params) do
    %{
      since: parse_date(params["since"]),
      until: parse_date(params["until"]),
      entity_id: params["entity_id"] |> to_string() |> String.trim(),
      action: params["action"] || "all"
    }
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp load_versions(socket) do
    versions = read_versions(socket.assigns.filters)
    assign(socket, :versions, versions)
  end

  defp read_versions(filters) do
    query = Ash.Query.new(Version) |> Ash.Query.sort(version_inserted_at: :desc)

    query =
      query
      |> filter_by_action(filters.action)
      |> filter_by_entity_id(filters.entity_id)
      |> filter_by_since(filters.since)
      |> filter_by_until(filters.until)
      |> Ash.Query.limit(500)

    Ash.read!(query)
  end

  defp filter_by_action(query, "all"), do: query

  defp filter_by_action(query, action) when action in ~w(create update close reopen) do
    atom = String.to_existing_atom(action)
    Ash.Query.filter(query, version_action_name == ^atom)
  end

  defp filter_by_action(query, _), do: query

  defp filter_by_entity_id(query, ""), do: query

  defp filter_by_entity_id(query, eid) do
    pattern = "%" <> eid <> "%"
    Ash.Query.filter(query, like(version_source_id, ^pattern))
  end

  defp filter_by_since(query, nil), do: query

  defp filter_by_since(query, %Date{} = d) do
    dt = DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
    Ash.Query.filter(query, version_inserted_at >= ^dt)
  end

  defp filter_by_until(query, nil), do: query

  defp filter_by_until(query, %Date{} = d) do
    # `until` is inclusive — use end-of-day.
    dt = DateTime.new!(d, ~T[23:59:59.999999], "Etc/UTC")
    Ash.Query.filter(query, version_inserted_at <= ^dt)
  end

  defp versions_to_export(versions) do
    Enum.map(versions, fn v ->
      %{
        id: v.id,
        task_id: v.version_source_id,
        action: v.version_action_name,
        action_type: v.version_action_type,
        inputs: v.version_action_inputs,
        changes: v.changes,
        at: v.version_inserted_at
      }
    end)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6" id="audit-log" phx-hook="DownloadOnEvent">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <.icon name="hero-clock" class="size-6 text-base-content/70" /> Audit log
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            {length(@versions)} most recent directive changes (max 500), sourced from
            <code class="text-xs">ash_paper_trail</code>
            versions on <code class="text-xs">Arbiter.Tasks.Issue</code>.
          </p>
        </div>

        <%!-- ── Filter bar ───────────────────────────────────────────── --%>
        <form
          phx-change="filter"
          phx-submit="filter"
          class="card bg-base-200 border border-base-300 shadow-sm"
        >
          <div class="card-body p-4 gap-4">
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <label class="form-control">
                <span class="label-text text-xs font-medium text-base-content/60 mb-1 flex items-center gap-1">
                  <.icon name="hero-calendar-days" class="size-3.5" /> Since
                </span>
                <input
                  type="date"
                  name="filters[since]"
                  value={iso_or_blank(@filters.since)}
                  class="input input-bordered input-sm w-full"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs font-medium text-base-content/60 mb-1 flex items-center gap-1">
                  <.icon name="hero-calendar-days" class="size-3.5" /> Until
                </span>
                <input
                  type="date"
                  name="filters[until]"
                  value={iso_or_blank(@filters.until)}
                  class="input input-bordered input-sm w-full"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs font-medium text-base-content/60 mb-1 flex items-center gap-1">
                  <.icon name="hero-hashtag" class="size-3.5" /> Task id contains
                </span>
                <input
                  type="text"
                  name="filters[entity_id]"
                  value={@filters.entity_id}
                  placeholder="gte- · hq- · …"
                  class="input input-bordered input-sm w-full"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs font-medium text-base-content/60 mb-1 flex items-center gap-1">
                  <.icon name="hero-funnel" class="size-3.5" /> Action
                </span>
                <select name="filters[action]" class="select select-bordered select-sm w-full">
                  <option
                    :for={opt <- ~w(all create update close reopen)}
                    value={opt}
                    selected={@filters.action == opt}
                  >
                    {opt}
                  </option>
                </select>
              </label>
            </div>

            <div class="flex flex-wrap items-center gap-2 pt-1 border-t border-base-300 mt-1">
              <button
                type="button"
                phx-click="reset"
                class="btn btn-sm btn-ghost gap-1.5 active:scale-95 transition-transform"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Reset
              </button>
              <div class="flex-1"></div>
              <button
                type="button"
                phx-click="export"
                class="btn btn-sm btn-primary gap-1.5 active:scale-95 transition-transform"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Export as JSON
              </button>
            </div>
          </div>
        </form>

        <%!-- ── Event stream ─────────────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <div
              :if={@versions == []}
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-8 text-center"
            >
              <.icon name="hero-inbox" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">No matching audit events.</p>
            </div>

            <ol :if={@versions != []} id="audit-stream" class="relative flex flex-col">
              <li
                :for={v <- @versions}
                class="group relative flex gap-3 pb-4 last:pb-0 pl-1 transition-colors duration-150"
              >
                <%!-- timeline rail + node --%>
                <div class="relative flex flex-col items-center shrink-0">
                  <span class={[
                    "z-10 flex items-center justify-center size-8 rounded-full ring-4 ring-base-200",
                    action_dot_class(v.version_action_name)
                  ]}>
                    <.icon name={action_icon(v.version_action_name)} class="size-4" />
                  </span>
                  <span class="absolute top-8 bottom-0 w-px bg-base-300"></span>
                </div>

                <%!-- event body --%>
                <div class="min-w-0 flex-1 -mt-0.5 rounded-box bg-base-100 border border-base-300 px-3 py-2 transition-colors duration-150 group-hover:border-base-content/20">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={action_badge_class(v.version_action_name)}>
                      {v.version_action_name}
                    </span>
                    <code class="text-xs text-base-content/70">{v.version_source_id}</code>
                    <span class="flex-1"></span>
                    <span class="text-xs text-base-content/50 font-mono tabular-nums whitespace-nowrap">
                      {Calendar.strftime(v.version_inserted_at, "%Y-%m-%d %H:%M:%S")}
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
      </div>
    </Layouts.app>
    """
  end

  defp iso_or_blank(nil), do: ""
  defp iso_or_blank(%Date{} = d), do: Date.to_iso8601(d)

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

  defp format_changes(changes) when is_map(changes) do
    changes
    |> Map.take(["status", "title", "priority", "tracker_type", "assignee"])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp format_changes(_), do: ""
end
