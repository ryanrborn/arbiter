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
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.Paging
  require Ash.Query

  @workers_topic "workers"

  @filters [
    %{label: "All", value: "all"},
    %{label: "Running", value: "running"},
    %{label: "Completed", value: "completed"},
    %{label: "Failed", value: "failed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)

    {:ok,
     socket
     |> assign(:worker_label, "worker")
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
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <Domain.index_header
            icon="hero-clock"
            title={"#{cap_plural(@worker_label)} history"}
            count={@total_count}
            subtitle={"Every recorded #{@worker_label} run. The dashboard shows only the most recent."}
          />
          <Feedback.live_badge live={@live} />
        </div>

        <Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> run_path(String.to_existing_atom(value), 1) end}
        />

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@runs == []} id="runs-empty">
            <Feedback.empty_state icon="hero-moon">
              No {@worker_label} runs match this filter.
            </Feedback.empty_state>
          </div>

          <ul :if={@runs != []} id="runs-history" class="flex flex-col gap-3">
            <li :for={r <- @runs}>
              <.link navigate={~p"/workers/history/#{r.id}"} class="block no-underline">
                <Domain.run_row
                  worker={r.task_id}
                  outcome={r.task_title || r.task_id}
                  status={r.status}
                  duration={humanize_duration(r.started_at, r.completed_at)}
                  role={r.worker_type}
                  selected={false}
                  expanded={false}
                  class="cursor-pointer hover:bg-[var(--surface-raised)]"
                />
              </.link>
            </li>
          </ul>

          <Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> run_path(@status, page) end}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: nil

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
