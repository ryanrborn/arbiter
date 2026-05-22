defmodule ArbiterWeb.BeadDetailLive do
  @moduledoc """
  Per-bead detail view at `/beads/:id` — combines the resource record,
  any active polecat, dependency edges, and recent audit-log versions
  into one page. Re-renders on `:bead_lifecycle` and `:polecat_lifecycle`
  events so the page stays current.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Dependency
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Issue.Version
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  require Ash.Query

  @beads_topic "beads"
  @polecats_topic "polecats"

  @impl true
  def mount(%{"id" => bead_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @beads_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @polecats_topic)
    end

    {:ok,
     socket
     |> assign(:bead_id, bead_id)
     |> assign(:live, connected?(socket))
     |> refresh_all()}
  end

  @impl true
  def handle_info({:bead_lifecycle, _event, %{id: id}}, %{assigns: %{bead_id: id}} = socket) do
    {:noreply, refresh_all(socket)}
  end

  # Lifecycle events for other beads can still affect this page's
  # dependency section (status of a target changed), so refresh on any.
  def handle_info({:bead_lifecycle, _event, _other}, socket) do
    {:noreply, refresh_deps(socket)}
  end

  def handle_info({:polecat_lifecycle, _event, %{bead_id: id}}, %{assigns: %{bead_id: id}} = socket) do
    {:noreply, refresh_polecat(socket)}
  end

  def handle_info({:polecat_lifecycle, _event, _snap}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  # ---- data ----

  defp refresh_all(socket) do
    socket
    |> refresh_bead()
    |> refresh_workspace()
    |> refresh_polecat()
    |> refresh_deps()
    |> refresh_versions()
  end

  defp refresh_bead(socket) do
    case Ash.get(Issue, socket.assigns.bead_id) do
      {:ok, bead} -> assign(socket, :bead, bead)
      {:error, _} -> assign(socket, :bead, nil)
    end
  end

  defp refresh_workspace(%{assigns: %{bead: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  defp refresh_polecat(socket) do
    snap =
      case Polecat.whereis(socket.assigns.bead_id) do
        nil -> nil
        pid -> safe_state(pid)
      end

    assign(socket, :polecat, snap)
  end

  defp safe_state(pid) do
    Polecat.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp refresh_deps(socket) do
    id = socket.assigns.bead_id

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
        |> Ash.Query.filter(version_source_id == ^socket.assigns.bead_id)
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
    <div class="p-6 max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">
          Bead <code>{@bead_id}</code>
        </h1>
        <span class={[
          "badge badge-sm",
          if(@live, do: "badge-success", else: "badge-warning")
        ]}>
          <%= if @live do %>
            ● live
          <% else %>
            ⚠ stale (refresh)
          <% end %>
        </span>
      </div>

      <%= if @bead do %>
        <section class="card bg-base-200 p-4 mb-4">
          <h2 class="text-lg font-semibold mb-2">{@bead.title}</h2>
          <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
            <dt class="font-semibold">Status:</dt>
            <dd>
              <span class={["badge", status_badge_class(@bead.status)]}>
                {@bead.status}
              </span>
            </dd>
            <dt class="font-semibold">Type:</dt>
            <dd>{@bead.issue_type}</dd>
            <dt class="font-semibold">Priority:</dt>
            <dd>P{@bead.priority}</dd>
            <dt class="font-semibold">Workspace:</dt>
            <dd>
              <%= if @workspace do %>
                {@workspace.name}
                <span class="text-base-content/60">
                  (<code>{@workspace.prefix}</code>)
                </span>
              <% else %>
                <span class="text-base-content/60">(none)</span>
              <% end %>
            </dd>
            <%= if @bead.tracker_type != :none do %>
              <dt class="font-semibold">Tracker:</dt>
              <dd>{@bead.tracker_type} {@bead.tracker_ref}</dd>
            <% end %>
            <%= if @bead.assignee do %>
              <dt class="font-semibold">Assignee:</dt>
              <dd>{@bead.assignee}</dd>
            <% end %>
          </dl>

          <%= if @bead.description do %>
            <h3 class="text-sm font-semibold mt-4 mb-1">Description</h3>
            <pre class="whitespace-pre-wrap text-xs bg-base-300 p-3 rounded">{@bead.description}</pre>
          <% end %>

          <%= if @bead.acceptance do %>
            <h3 class="text-sm font-semibold mt-4 mb-1">Acceptance</h3>
            <pre class="whitespace-pre-wrap text-xs bg-base-300 p-3 rounded">{@bead.acceptance}</pre>
          <% end %>
        </section>

        <section class="card bg-base-200 p-4 mb-4">
          <div class="flex items-center justify-between mb-2">
            <h2 class="text-lg font-semibold">Polecat</h2>
            <%= if @polecat do %>
              <.link
                navigate={~p"/polecats/#{@bead_id}"}
                class="link link-hover text-sm"
              >
                view full output →
              </.link>
            <% end %>
          </div>
          <%= if @polecat do %>
            <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
              <dt class="font-semibold">Status:</dt>
              <dd>
                <span class={["badge badge-sm", polecat_status_class(@polecat.status)]}>
                  {@polecat.status}
                </span>
              </dd>
              <dt class="font-semibold">Step:</dt>
              <dd>{@polecat.current_step}</dd>
              <dt class="font-semibold">Started:</dt>
              <dd>{@polecat.started_at}</dd>
            </dl>
          <% else %>
            <p class="text-base-content/60 italic">
              No polecat running for this bead. Use
              <code>arb sling {@bead_id}</code> to spawn one.
            </p>
          <% end %>
        </section>

        <div class="grid grid-cols-2 gap-4 mb-4">
          <section class="card bg-base-200 p-4">
            <h2 class="text-lg font-semibold mb-2">
              Blocked by ({length(@outbound_deps)})
            </h2>
            <%= if @outbound_deps == [] do %>
              <p class="text-base-content/60 italic text-sm">No outgoing dependencies.</p>
            <% else %>
              <ul class="text-sm space-y-1">
                <%= for d <- @outbound_deps do %>
                  <li>
                    <span class="badge badge-sm">{d.type}</span>
                    <.link navigate={~p"/beads/#{d.to_issue_id}"} class="link link-hover">
                      <code class="text-xs">{d.to_issue_id}</code>
                    </.link>
                    <%= if d.other_issue do %>
                      — <span class={["badge badge-xs", status_badge_class(d.other_issue.status)]}>
                        {d.other_issue.status}
                      </span>
                      <span class="text-base-content/70">{d.other_issue.title}</span>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </section>

          <section class="card bg-base-200 p-4">
            <h2 class="text-lg font-semibold mb-2">
              Blocks ({length(@inbound_deps)})
            </h2>
            <%= if @inbound_deps == [] do %>
              <p class="text-base-content/60 italic text-sm">Nothing depends on this bead.</p>
            <% else %>
              <ul class="text-sm space-y-1">
                <%= for d <- @inbound_deps do %>
                  <li>
                    <span class="badge badge-sm">{d.type}</span>
                    <.link navigate={~p"/beads/#{d.from_issue_id}"} class="link link-hover">
                      <code class="text-xs">{d.from_issue_id}</code>
                    </.link>
                    <%= if d.other_issue do %>
                      — <span class={["badge badge-xs", status_badge_class(d.other_issue.status)]}>
                        {d.other_issue.status}
                      </span>
                      <span class="text-base-content/70">{d.other_issue.title}</span>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </section>
        </div>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-2">
            History ({length(@versions)})
          </h2>
          <%= if @versions == [] do %>
            <p class="text-base-content/60 italic text-sm">No history recorded.</p>
          <% else %>
            <ul class="text-sm space-y-1">
              <%= for v <- @versions do %>
                <li class="flex gap-3">
                  <span class="text-xs text-base-content/60 w-44 shrink-0">
                    {v.version_inserted_at}
                  </span>
                  <span class="badge badge-sm">{v.version_action_name}</span>
                  <span class="text-xs text-base-content/70 truncate">
                    {inspect(v.changes)}
                  </span>
                </li>
              <% end %>
            </ul>
          <% end %>
        </section>
      <% else %>
        <p class="text-base-content/60">
          Bead <code>{@bead_id}</code> not found.
        </p>
      <% end %>

      <div class="mt-6">
        <.link navigate={~p"/"} class="link link-hover">← Back to dashboard</.link>
      </div>
    </div>
    </Layouts.app>
    """
  end

  defp status_badge_class(:open), do: "badge-info"
  defp status_badge_class(:in_progress), do: "badge-warning"
  defp status_badge_class(:closed), do: "badge-success"
  defp status_badge_class(_), do: ""

  defp polecat_status_class(:running), do: "badge-info"
  defp polecat_status_class(:awaiting), do: "badge-warning"
  defp polecat_status_class(:completed), do: "badge-success"
  defp polecat_status_class(:failed), do: "badge-error"
  defp polecat_status_class(_), do: ""
end
