defmodule ArbiterWeb.RunIndexLive do
  @moduledoc """
  Index of every worker run at `/workers/history` — the "See all" target for
  the dashboard's completed-workers section.

  Lists all persisted `Arbiter.Workers.Run` records (the durable post-mortem
  of each worker execution) with a status filter and paging, newest first.
  Each row links to the run detail page. Re-renders live on
  `:worker_lifecycle` events so a freshly-finished run appears without a
  refresh.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Workers.Run
  alias ArbiterWeb.Paging
  require Ash.Query

  @workers_topic "workers"

  @filters [
    {"All", :all},
    {"Running", :running},
    {"Completed", :completed},
    {"Failed", :failed}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)

    {:ok,
     socket
     |> assign(:live, connected?(socket))
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
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    query =
      Run
      |> filter_by_status(socket.assigns.status)
      |> Ash.Query.sort(started_at: :desc)

    result = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:runs, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp filter_by_status(query, :all), do: Ash.Query.new(query)
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp parse_status(%{"status" => s}) when s in ~w(running completed failed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp run_path(:all, page), do: ~p"/workers/history?#{%{page: page}}"
  defp run_path(status, page), do: ~p"/workers/history?#{%{status: status, page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-clock"
            title={"#{String.capitalize(@worker_label)} history"}
            count={@total_count}
            subtitle={"Every recorded #{@worker_label} run. The dashboard shows only the most recent."}
          />
          <.live_badge live={@live} />
        </div>

        <.filter_tabs
          tabs={@filters}
          active={@status}
          tab_path={fn value -> run_path(value, 1) end}
        />

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <.empty_state :if={@runs == []} id="runs-empty" icon="hero-archive-box">
              No {@worker_label} runs match this filter.
            </.empty_state>

            <div :if={@runs != []} class="overflow-x-auto">
              <table class="table table-sm" id="runs">
                <thead>
                  <tr class="text-base-content/60">
                    <th>{String.capitalize(@issue_label)}</th>
                    <th>Title</th>
                    <th>Type</th>
                    <th>Status</th>
                    <th>Started</th>
                    <th class="text-right">Duration</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={r <- @runs} class="hover:bg-base-300/40 transition-colors">
                    <td>
                      <.link navigate={~p"/workers/history/#{r.id}"} class="link link-hover">
                        <code class="text-xs">{r.task_id}</code>
                      </.link>
                    </td>
                    <td class="text-xs max-w-xs truncate" title={r.task_title || ""}>
                      {r.task_title || "—"}
                    </td>
                    <td>
                      <span class="badge badge-sm badge-ghost">{r.worker_type}</span>
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

            <.pager
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> run_path(@status, page) end}
            />
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp run_status_class(:completed), do: "badge-success"
  defp run_status_class(:failed), do: "badge-error"
  defp run_status_class(:running), do: "badge-info"
  defp run_status_class(_), do: "badge-ghost"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_ts(_), do: "—"

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
