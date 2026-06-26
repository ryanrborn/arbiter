defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  closed) and offset/limit paging, newest-updated first. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue
  alias ArbiterWeb.Paging
  require Ash.Query

  @tasks_topic "tasks"

  @filters [
    {"All", :all},
    {"Open", :open},
    {"In progress", :in_progress},
    {"Closed", :closed}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:issue_label, "issue")
     |> assign(:filters, @filters)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = parse_status(params)
    page = Paging.parse_page(params)

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:page, page)
     |> refresh()}
  end

  @impl true
  # Any task transition can change which rows belong on the current page;
  # re-read the page in place (same filter + page).
  def handle_info({:task_lifecycle, _event, _issue}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    query =
      Issue
      |> filter_by_status(socket.assigns.status)
      |> Ash.Query.sort(updated_at: :desc)

    result = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:tasks, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp filter_by_status(query, :all), do: Ash.Query.new(query)
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp parse_status(%{"status" => s}) when s in ~w(open in_progress closed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  # ---- routes ----

  defp task_path(:all, page), do: ~p"/tasks?#{%{page: page}}"
  defp task_path(status, page), do: ~p"/tasks?#{%{status: status, page: page}}"

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-clipboard-document-list"
            title={cap_plural(@issue_label)}
            count={@total_count}
            subtitle={"Every #{@issue_label}, filterable and paged. The dashboard shows only the current ones."}
          />
          <.live_badge live={@live} />
        </div>

        <.filter_tabs
          tabs={@filters}
          active={@status}
          tab_path={fn value -> task_path(value, 1) end}
        />

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <.empty_state :if={@tasks == []} id="tasks-empty" icon="hero-clipboard-document-list">
              No {plural(@issue_label)} match this filter.
            </.empty_state>

            <ul :if={@tasks != []} id="tasks" class="flex flex-col gap-1.5">
              <li
                :for={b <- @tasks}
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
                  <span class={[
                    "badge badge-sm font-mono shrink-0",
                    difficulty_badge_class(b.difficulty)
                  ]}>
                    {difficulty_label(b.difficulty)}
                  </span>
                  <.link navigate={~p"/tasks/#{b.id}"} class="min-w-0 flex-1 group">
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
                  <span class={["badge badge-sm shrink-0", status_badge_class(b.status)]}>
                    {b.status}
                  </span>
                </div>
              </li>
            </ul>

            <.pager
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> task_path(@status, page) end}
            />
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp status_badge_class(:open), do: "badge-success"
  defp status_badge_class(:in_progress), do: "badge-info"
  defp status_badge_class(:closed), do: "badge-ghost"
  defp status_badge_class(_), do: ""

  defp difficulty_label(nil), do: "—"
  defp difficulty_label(d) when is_integer(d) and d in 0..4, do: "D#{d}"
  defp difficulty_label(_), do: "—"

  defp difficulty_badge_class(0), do: "badge-success"
  defp difficulty_badge_class(1), do: "badge-info"
  defp difficulty_badge_class(2), do: "badge-secondary"
  defp difficulty_badge_class(3), do: "badge-warning"
  defp difficulty_badge_class(4), do: "badge-error"
  defp difficulty_badge_class(_), do: "badge-ghost"
end
