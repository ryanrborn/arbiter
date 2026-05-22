defmodule ArbiterWeb.AuditLogLive do
  @moduledoc """
  LiveView at `/audit` — timeline of bead state transitions sourced from
  `AshPaperTrail` versions on `Arbiter.Beads.Issue`.

  ## What's in scope (MVP)

  Every paper-trail `Version` row for an Issue:
    - create
    - update
    - close
    - reopen

  Filters:
    - **Date range** (`since` / `until` — ISO date strings, both inclusive).
    - **Entity ID** (bead id; partial match against `version_source_id`).
    - **Action name** (create | update | close | reopen | all).

  ## What's NOT in scope (Phase 5)

    - Actor filter (paper_trail's default config doesn't track who; needs
      `belongs_to_actor :user, User` setup or a sidecar audit table).
    - Polecat lifecycle events (no audit resource yet).
    - PR/merge events (gte-022/023 don't write to paper_trail).

  The acceptance criterion's "filter by actor=mayor" is therefore
  approximated: the JSON `version_action_inputs` map sometimes contains
  bead fields with author names (e.g. assignee). MVP punts on this; once
  `belongs_to_actor` is wired (a separate Phase 5 bead), the filter form
  here will be extended.

  ## Export

  "Export as JSON" downloads the currently-filtered version list as a
  JSON-array file via a redirect to `GET /audit/export`.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Issue.Version
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
        bead_id: v.version_source_id,
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
    <Layouts.app flash={@flash} current_path={@current_path}>
    <div class="p-6 max-w-7xl mx-auto" id="audit-log" phx-hook="DownloadOnEvent">
      <h1 class="text-2xl font-bold mb-4">Audit log</h1>
      <p class="text-sm text-base-content/70 mb-6">
        Showing the {length(@versions)} most recent bead changes (max 500). Sourced
        from <code>ash_paper_trail</code> versions on
        <code>Arbiter.Beads.Issue</code>.
      </p>

      <form phx-change="filter" phx-submit="filter" class="card bg-base-200 p-4 mb-6">
        <div class="grid grid-cols-4 gap-4">
          <label class="form-control">
            <span class="label-text">Since</span>
            <input
              type="date"
              name="filters[since]"
              value={iso_or_blank(@filters.since)}
              class="input input-bordered input-sm"
            />
          </label>
          <label class="form-control">
            <span class="label-text">Until</span>
            <input
              type="date"
              name="filters[until]"
              value={iso_or_blank(@filters.until)}
              class="input input-bordered input-sm"
            />
          </label>
          <label class="form-control">
            <span class="label-text">Bead id contains</span>
            <input
              type="text"
              name="filters[entity_id]"
              value={@filters.entity_id}
              placeholder="gte- · hq- · …"
              class="input input-bordered input-sm"
            />
          </label>
          <label class="form-control">
            <span class="label-text">Action</span>
            <select name="filters[action]" class="select select-bordered select-sm">
              <%= for opt <- ~w(all create update close reopen) do %>
                <option value={opt} selected={@filters.action == opt}>{opt}</option>
              <% end %>
            </select>
          </label>
        </div>

        <div class="flex gap-2 mt-3">
          <button type="button" phx-click="reset" class="btn btn-sm btn-ghost">
            Reset
          </button>
          <button type="button" phx-click="export" class="btn btn-sm btn-primary">
            Export as JSON
          </button>
        </div>
      </form>

      <table class="table table-zebra table-sm">
        <thead>
          <tr>
            <th>When</th>
            <th>Bead</th>
            <th>Action</th>
            <th>Changes</th>
          </tr>
        </thead>
        <tbody>
          <%= for v <- @versions do %>
            <tr>
              <td class="text-xs whitespace-nowrap">
                {Calendar.strftime(v.version_inserted_at, "%Y-%m-%d %H:%M:%S")}
              </td>
              <td>
                <code class="text-xs">{v.version_source_id}</code>
              </td>
              <td>
                <span class={action_badge_class(v.version_action_name)}>
                  {v.version_action_name}
                </span>
              </td>
              <td class="text-xs">
                {format_changes(v.changes)}
              </td>
            </tr>
          <% end %>
          <%= if @versions == [] do %>
            <tr>
              <td colspan="4" class="text-center text-base-content/50 italic py-6">
                No matching audit events.
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
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

  defp format_changes(changes) when is_map(changes) do
    changes
    |> Map.take(["status", "title", "priority", "tracker_type", "assignee"])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp format_changes(_), do: ""
end
