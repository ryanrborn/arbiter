defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  closed) and offset/limit paging, newest-updated first. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.

  The "New issue" action navigates to the standalone `/tasks/new` create
  screen (`ArbiterWeb.TaskNewLive`) rather than opening an inline form here.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue
  alias ArbiterWeb.Paging
  require Ash.Query

  @tasks_topic "tasks"

  # Literal status values — FilterTabs shows these verbatim, not humanized,
  # so the value here is what lands in the URL and the query filter.
  @filters [
    %{label: "All", value: "all"},
    %{label: "Open", value: "open"},
    %{label: "In progress", value: "in_progress"},
    %{label: "Closed", value: "closed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    {:ok,
     socket
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
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-clipboard-document-list"
          title={cap_plural(@issue_label)}
          count={@total_count}
          subtitle={"Every #{@issue_label}, filterable and paged. The dashboard shows only the current ones."}
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
            <ArbiterWeb.CoreComponents.Core.button
              type="button"
              variant="primary"
              size="sm"
              phx-click={JS.navigate(~p"/tasks/new")}
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
              New {@issue_label}
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <ArbiterWeb.CoreComponents.Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> task_path(String.to_existing_atom(value), 1) end}
        />

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@tasks == []} id="tasks-empty">
            <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-clipboard-document-list">
              No {plural(@issue_label)} match this filter.
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>

          <ul :if={@tasks != []} id="tasks" class="flex flex-col gap-1.5">
            <li :for={b <- @tasks} class={issue_row_class(b)}>
              <.priority_tag priority={b.priority} />
              <.difficulty_meter difficulty={b.difficulty} />
              <.link
                navigate={~p"/tasks/#{b.id}"}
                class="min-w-0 flex-1 flex items-center gap-2 group"
              >
                <span class="font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)] shrink-0 group-hover:text-[var(--text-link)] transition-colors">
                  {b.id}
                </span>
                <span
                  class="truncate text-[12.5px] font-medium text-[var(--text-title)] group-hover:text-[var(--text-link)] transition-colors"
                  title={b.title}
                >
                  {b.title}
                </span>
              </.link>
              <.status_chip status={b.status} />
            </li>
          </ul>

          <ArbiterWeb.CoreComponents.Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> task_path(@status, page) end}
            class={@tasks != [] && "pt-2"}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  # P1 is the only priority that owns the row: a red left rule plus a faint
  # wash, matching the accent-rule treatment `Domain.task_card/1` uses for
  # its `fail` accent. Closed issues recede instead — opacity 0.62, no rule.
  defp issue_row_class(issue) do
    [
      "flex items-center gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid",
      "border-[var(--border-strong)] hover:bg-[var(--arb-raised-hover)]",
      "transition-colors duration-[var(--dur-hover)]",
      if(issue.priority == 1,
        do: [
          "bg-[var(--arb-fail-wash)]",
          "border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-fail)]"
        ],
        else: "bg-[var(--surface-card)]"
      ),
      issue.status == :closed && "opacity-[0.62]"
    ]
  end
end
