defmodule ArbiterWeb.WorkerIndexLive do
  @moduledoc """
  Index of every active worker (worker) at `/workers` — the "See all"
  target for the dashboard's active-workers section.

  Workers are live GenServer state, not rows, so the listing comes from
  `Worker.list_children/0` and is paged in memory. A status filter narrows to
  running vs awaiting work. Re-renders live on `:worker_lifecycle` events and
  on a 1s tick (for the elapsed counters). Each row links to the worker
  detail page; completed/failed runs live on the run history index instead.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias ArbiterWeb.Paging

  @workers_topic "workers"

  @filters [
    {"All", :all},
    {"Running", :running},
    {"Awaiting", :awaiting}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:now, DateTime.utc_now())
     |> assign(:worker_label, "worker")
     |> assign(:issue_label, "issue")
     |> assign(:filters, @filters)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:status, parse_status(params))
     |> assign(:page, Paging.parse_page(params))
     |> refresh()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    workspaces_by_id = index_workspaces()

    all =
      list_children()
      |> Enum.map(fn p ->
        Map.put(p, :workspace_name, workspace_name(workspaces_by_id, p.workspace_id))
      end)
      |> Enum.filter(&matches_status?(&1, socket.assigns.status))
      |> Enum.sort_by(& &1.started_at, {:asc, DateTime})

    result = Paging.paginate_list(all, socket.assigns.page)

    socket
    |> assign(:workers, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp list_children do
    Worker.list_children()
  rescue
    _ -> []
  end

  defp index_workspaces do
    Ash.read!(Workspace) |> Map.new(fn ws -> {ws.id, ws} end)
  rescue
    _ -> %{}
  end

  defp workspace_name(_by_id, nil), do: "(none)"

  defp workspace_name(by_id, ws_id) do
    case Map.fetch(by_id, ws_id) do
      {:ok, ws} -> ws.name
      :error -> "(unknown)"
    end
  end

  defp matches_status?(_p, :all), do: true
  defp matches_status?(%{status: :running}, :running), do: true

  defp matches_status?(%{status: status}, :awaiting),
    do: status in [:awaiting, :awaiting_review, :awaiting_review_gate]

  defp matches_status?(_p, _), do: false

  defp parse_status(%{"status" => s}) when s in ~w(running awaiting),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp worker_path(:all, page), do: ~p"/workers?#{%{page: page}}"
  defp worker_path(status, page), do: ~p"/workers?#{%{status: status, page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-cpu-chip"
            title={"Active #{cap_plural(@worker_label)}"}
            count={@total_count}
            subtitle={"Every #{@worker_label} running right now. Finished runs live on the history index."}
          />
          <.live_badge live={@live} />
        </div>

        <.filter_tabs
          tabs={@filters}
          active={@status}
          tab_path={fn value -> worker_path(value, 1) end}
        />

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <.empty_state :if={@workers == []} id="workers-empty" icon="hero-moon">
              No active {plural(@worker_label)} match this filter.
            </.empty_state>

            <ul :if={@workers != []} id="workers" class="flex flex-col gap-3">
              <li
                :for={p <- @workers}
                class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-info/50"
              >
                <div class="flex items-center justify-between gap-2">
                  <.link
                    navigate={~p"/workers/#{p.task_id}"}
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
                      {p.task_id}
                    </code>
                  </.link>
                  <span class={["badge badge-sm shrink-0", worker_status_class(p.status)]}>
                    {worker_status_label(p.status)}
                  </span>
                </div>
                <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                  <span class="truncate">{p.workspace_name}</span>
                  <span class="font-mono tabular-nums shrink-0" title="Elapsed">
                    {humanize_seconds(runtime_seconds(p.started_at, @now))}
                  </span>
                </div>
              </li>
            </ul>

            <.pager
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> worker_path(@status, page) end}
            />
          </div>
        </section>

        <div class="flex items-center gap-4">
          <.back_link />
          <.link
            navigate={~p"/workers/history"}
            class="link link-hover text-sm flex items-center gap-1"
          >
            <.icon name="hero-clock" class="size-4" /> History (completed {plural(@worker_label)})
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp status_dot_class(:running), do: "bg-info"
  defp status_dot_class(:awaiting), do: "bg-warning"
  defp status_dot_class(:awaiting_review), do: "bg-warning"
  defp status_dot_class(:awaiting_review_gate), do: "bg-warning"
  defp status_dot_class(:completed), do: "bg-success"
  defp status_dot_class(:failed), do: "bg-error"
  defp status_dot_class(_), do: "bg-base-content/30"

  defp worker_status_class(:idle), do: "badge-ghost"
  defp worker_status_class(:resuming), do: "badge-info"
  defp worker_status_class(:running), do: "badge-info"
  defp worker_status_class(:awaiting), do: "badge-warning"
  defp worker_status_class(:awaiting_review_gate), do: "badge-warning"
  defp worker_status_class(:awaiting_review), do: "badge-warning"
  defp worker_status_class(:completed), do: "badge-success"
  defp worker_status_class(:failed), do: "badge-error"
  defp worker_status_class(_), do: ""

  defp worker_status_label(:idle), do: "Idle"
  defp worker_status_label(:resuming), do: "Resuming"
  defp worker_status_label(:running), do: "Running"
  defp worker_status_label(:awaiting), do: "Awaiting"
  defp worker_status_label(:awaiting_review_gate), do: "In review_gate"
  defp worker_status_label(:awaiting_review), do: "Awaiting review"
  defp worker_status_label(:completed), do: "Completed"
  defp worker_status_label(:failed), do: "Failed"

  defp worker_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp worker_status_label(other), do: to_string(other)
end
