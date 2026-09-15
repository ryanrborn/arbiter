defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  awaiting verification / closed), a text search, and a combinable set of
  filters (workspace, type, priority, difficulty, backlog/ready stage, repo,
  parent epic), paginated with offset/limit and sortable by updated / created
  / priority / difficulty. Every bit of that state — search, filters, sort,
  page — round-trips through the URL query string via `push_patch`, so a
  filtered view is shareable and survives reload. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.

  The "New issue" action navigates to the standalone `/tasks/new` create
  screen (`ArbiterWeb.TaskNewLive`) rather than opening an inline form here.

  ## Filtering strategy

  Every filter is pushed into the `Ash.Query` (see `refresh/1`) rather than
  applied in-memory, so `Paging.paginate/2`'s LIMIT/OFFSET stays correct
  under any combination. Text search matches id, title, and description
  substrings via SQLite's `LIKE` (case-insensitive for ASCII by default —
  same precedent as `AuditLogLive`'s `subject:` clause). The parent-epic
  filter is the one exception worth calling out: it resolves the epic's
  `:parent_of` children (or every parented issue, for "no parent") into an
  id list first, then filters `id in ^ids` / `id not in ^ids` — still a real
  SQL `IN` clause, just built from a precomputed list rather than a joined
  subquery, since AshSqlite has no cross-resource `exists` filter here.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias ArbiterWeb.Paging
  require Ash.Query

  @tasks_topic "tasks"

  # Literal status values — FilterTabs shows these verbatim, not humanized,
  # so the value here is what lands in the URL and the query filter.
  @filter_tabs [
    %{label: "All", value: "all"},
    %{label: "Open", value: "open"},
    %{label: "In progress", value: "in_progress"},
    %{label: "Awaiting verification", value: "awaiting_verification"},
    %{label: "Closed", value: "closed"}
  ]

  @sorts ~w(updated created priority difficulty)a
  @sort_labels %{
    updated: "Last updated",
    created: "Newest first",
    priority: "Priority",
    difficulty: "Difficulty"
  }

  @issue_types Issue.issue_types()
  @priorities 0..4
  @difficulties 0..5

  @default_filters %{
    status: :all,
    q: "",
    workspace: nil,
    type: nil,
    priority: nil,
    difficulty: nil,
    stage: nil,
    repo: nil,
    epic: nil,
    sort: :updated
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    {:ok,
     socket
     |> assign(:issue_label, "issue")
     |> assign(:filter_tabs, @filter_tabs)
     |> assign(:sort_options, Enum.map(@sorts, &{@sort_labels[&1], Atom.to_string(&1)}))
     |> assign(:workspaces, load_workspaces())
     |> assign(:epics, load_epics())
     |> assign(:repos, load_repos())
     |> assign(:issue_types, @issue_types)
     |> assign(:priorities, @priorities)
     |> assign(:difficulties, @difficulties)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    page = Paging.parse_page(params)

    {:noreply,
     socket
     |> assign(:f, filters)
     |> assign(:page, page)
     |> refresh()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: task_path(parse_filters(params), 1))}
  end

  # Any task transition can change which rows belong on the current page;
  # re-read the page in place (same filters + page).
  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- data ----

  defp refresh(socket) do
    query =
      Issue
      |> filter_by_status(socket.assigns.f.status)
      |> filter_by_query(socket.assigns.f.q)
      |> filter_by_workspace(socket.assigns.f.workspace)
      |> filter_by_type(socket.assigns.f.type)
      |> filter_by_priority(socket.assigns.f.priority)
      |> filter_by_difficulty(socket.assigns.f.difficulty)
      |> filter_by_stage(socket.assigns.f.stage)
      |> filter_by_repo(socket.assigns.f.repo)
      |> filter_by_epic(socket.assigns.f.epic)
      |> sort_by(socket.assigns.f.sort)

    result = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:tasks, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp load_workspaces, do: Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)

  defp load_epics do
    Issue
    |> Ash.Query.filter(issue_type == :epic)
    |> Ash.read!()
    |> Enum.sort_by(& &1.title)
  end

  defp load_repos do
    Issue
    |> Ash.Query.select([:repo])
    |> Ash.read!()
    |> Enum.map(& &1.repo)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---- query filters ----

  defp filter_by_status(query, :all), do: query
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp filter_by_query(query, ""), do: query

  defp filter_by_query(query, q) do
    pattern = "%#{q}%"

    Ash.Query.filter(
      query,
      like(id, ^pattern) or like(title, ^pattern) or like(description, ^pattern)
    )
  end

  defp filter_by_workspace(query, nil), do: query
  defp filter_by_workspace(query, id), do: Ash.Query.filter(query, workspace_id == ^id)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: Ash.Query.filter(query, issue_type == ^type)

  defp filter_by_priority(query, nil), do: query
  defp filter_by_priority(query, p), do: Ash.Query.filter(query, priority == ^p)

  defp filter_by_difficulty(query, nil), do: query
  defp filter_by_difficulty(query, :none), do: Ash.Query.filter(query, is_nil(difficulty))
  defp filter_by_difficulty(query, d), do: Ash.Query.filter(query, difficulty == ^d)

  defp filter_by_stage(query, nil), do: query
  defp filter_by_stage(query, :backlog), do: Ash.Query.filter(query, refined == false)
  defp filter_by_stage(query, :ready), do: Ash.Query.filter(query, refined == true)

  defp filter_by_repo(query, nil), do: query
  defp filter_by_repo(query, repo), do: Ash.Query.filter(query, repo == ^repo)

  defp filter_by_epic(query, nil), do: query

  defp filter_by_epic(query, :none) do
    parented_ids = parented_issue_ids()
    Ash.Query.filter(query, id not in ^parented_ids)
  end

  defp filter_by_epic(query, epic_id) do
    child_ids = children_of(epic_id)
    Ash.Query.filter(query, id in ^child_ids)
  end

  defp parented_issue_ids do
    parent_of = :parent_of

    Dependency
    |> Ash.Query.filter(type == ^parent_of)
    |> Ash.read!()
    |> Enum.map(& &1.to_issue_id)
    |> Enum.uniq()
  end

  defp children_of(epic_id) do
    parent_of = :parent_of

    Dependency
    |> Ash.Query.filter(type == ^parent_of and from_issue_id == ^epic_id)
    |> Ash.read!()
    |> Enum.map(& &1.to_issue_id)
  end

  defp sort_by(query, :updated), do: Ash.Query.sort(query, updated_at: :desc)
  defp sort_by(query, :created), do: Ash.Query.sort(query, created_at: :desc)
  defp sort_by(query, :priority), do: Ash.Query.sort(query, priority: :asc)
  defp sort_by(query, :difficulty), do: Ash.Query.sort(query, difficulty: :asc)

  # ---- URL <-> filter-state ----

  defp parse_filters(params) do
    %{
      status: parse_status(params),
      q: parse_q(params),
      workspace: parse_present_string(params, "workspace"),
      type: parse_type(params),
      priority: parse_priority(params),
      difficulty: parse_difficulty(params),
      stage: parse_stage(params),
      repo: parse_present_string(params, "repo"),
      epic: parse_epic(params),
      sort: parse_sort(params)
    }
  end

  defp parse_status(%{"status" => s}) when s in ~w(open in_progress awaiting_verification closed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp parse_q(%{"q" => q}) when is_binary(q), do: String.trim(q)
  defp parse_q(_), do: ""

  defp parse_present_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp parse_type(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "type"),
         true <- v in Enum.map(@issue_types, &Atom.to_string/1) do
      String.to_existing_atom(v)
    else
      _ -> nil
    end
  end

  defp parse_priority(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "priority"),
         {n, ""} <- Integer.parse(v),
         true <- n in @priorities do
      n
    else
      _ -> nil
    end
  end

  defp parse_difficulty(%{"difficulty" => "none"}), do: :none

  defp parse_difficulty(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "difficulty"),
         {n, ""} <- Integer.parse(v),
         true <- n in @difficulties do
      n
    else
      _ -> nil
    end
  end

  defp parse_stage(%{"stage" => s}) when s in ~w(backlog ready), do: String.to_existing_atom(s)
  defp parse_stage(_), do: nil

  defp parse_epic(%{"epic" => "none"}), do: :none
  defp parse_epic(params), do: parse_present_string(params, "epic")

  defp parse_sort(%{"sort" => s}) when s in ~w(updated created priority difficulty),
    do: String.to_existing_atom(s)

  defp parse_sort(_), do: :updated

  # ---- routes ----

  defp task_path(f, page) do
    %{}
    |> put_param(:status, f.status, @default_filters.status)
    |> put_param(:q, f.q, @default_filters.q)
    |> put_param(:workspace, f.workspace, @default_filters.workspace)
    |> put_param(:type, f.type, @default_filters.type)
    |> put_param(:priority, f.priority, @default_filters.priority)
    |> put_param(:difficulty, f.difficulty, @default_filters.difficulty)
    |> put_param(:stage, f.stage, @default_filters.stage)
    |> put_param(:repo, f.repo, @default_filters.repo)
    |> put_param(:epic, f.epic, @default_filters.epic)
    |> put_param(:sort, f.sort, @default_filters.sort)
    |> Map.put(:page, page)
    |> then(&~p"/tasks?#{&1}")
  end

  defp put_param(params, _key, default, default), do: params
  defp put_param(params, key, value, _default), do: Map.put(params, key, value)

  # ---- active-filter summary ----

  defp active_filter_summary(f, workspaces) do
    [
      f.status != :all && "status: #{f.status}",
      f.q != "" && "search: #{f.q}",
      f.workspace && "workspace: #{workspace_name(workspaces, f.workspace)}",
      f.type && "type: #{f.type}",
      f.priority && "priority: P#{f.priority}",
      f.difficulty == :none && "difficulty: unrated",
      is_integer(f.difficulty) && "difficulty: D#{f.difficulty}",
      f.stage && "stage: #{f.stage}",
      f.repo && "repo: #{f.repo}",
      f.epic == :none && "parent: none",
      is_binary(f.epic) && "parent: #{f.epic}"
    ]
    |> Enum.filter(& &1)
  end

  defp workspace_name(workspaces, id) do
    case Enum.find(workspaces, &(&1.id == id)) do
      %{name: name} -> name
      _ -> id
    end
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :active_filters, active_filter_summary(assigns.f, assigns.workspaces))

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
          tabs={@filter_tabs}
          active={Atom.to_string(@f.status)}
          tab_path={fn value -> task_path(%{@f | status: String.to_existing_atom(value)}, 1) end}
        />

        <form
          id="tasks-filter-form"
          phx-change="filter"
          class="flex flex-wrap items-end gap-2.5 p-3 rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--arb-canvas-sunken)]"
        >
          <div class="flex-1 min-w-[200px]">
            <ArbiterWeb.CoreComponents.Forms.input
              type="text"
              name="q"
              id="tasks-search"
              value={@f.q}
              placeholder="Search id or title…"
              phx-debounce="300"
              mono={false}
            />
          </div>

          <ArbiterWeb.CoreComponents.Forms.select
            name="workspace"
            id="tasks-filter-workspace"
            size="sm"
            prompt="Any workspace"
            value={@f.workspace || ""}
            options={Enum.map(@workspaces, &{&1.name, &1.id})}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="type"
            id="tasks-filter-type"
            size="sm"
            prompt="Any type"
            value={if @f.type, do: Atom.to_string(@f.type), else: ""}
            options={Enum.map(@issue_types, &{Phoenix.Naming.humanize(&1), Atom.to_string(&1)})}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="priority"
            id="tasks-filter-priority"
            size="sm"
            prompt="Any priority"
            value={if @f.priority, do: Integer.to_string(@f.priority), else: ""}
            options={Enum.map(@priorities, &{"P#{&1}", Integer.to_string(&1)})}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="difficulty"
            id="tasks-filter-difficulty"
            size="sm"
            prompt="Any difficulty"
            value={difficulty_select_value(@f.difficulty)}
            options={[
              {"Unrated", "none"} | Enum.map(@difficulties, &{"D#{&1}", Integer.to_string(&1)})
            ]}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="stage"
            id="tasks-filter-stage"
            size="sm"
            prompt="Backlog + Ready"
            value={if @f.stage, do: Atom.to_string(@f.stage), else: ""}
            options={[{"Backlog", "backlog"}, {"Ready", "ready"}]}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="repo"
            id="tasks-filter-repo"
            size="sm"
            prompt="Any repo"
            value={@f.repo || ""}
            options={@repos}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="epic"
            id="tasks-filter-epic"
            size="sm"
            prompt="Any parent"
            value={epic_select_value(@f.epic)}
            options={[
              {"No parent", "none"} | Enum.map(@epics, &{"#{&1.id} — #{&1.title}", &1.id})
            ]}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="sort"
            id="tasks-filter-sort"
            size="sm"
            value={Atom.to_string(@f.sort)}
            options={@sort_options}
          />

          <.link
            :if={@active_filters != []}
            id="tasks-clear-filters"
            patch={~p"/tasks"}
            class="text-[11.5px] text-[var(--text-link)] hover:underline whitespace-nowrap pb-1.5"
          >
            Clear filters
          </.link>
        </form>

        <div :if={@active_filters != []} id="tasks-active-filters" class="flex flex-wrap gap-1.5">
          <span
            :for={label <- @active_filters}
            class="badge badge-ghost text-[10.5px] font-[family-name:var(--font-mono)]"
          >
            {label}
          </span>
        </div>

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@tasks == []} id="tasks-empty">
            <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-clipboard-document-list">
              No {plural(@issue_label)} match
              <%= if @active_filters != [] do %>
                the active filters ({Enum.join(@active_filters, ", ")}).
              <% else %>
                this filter.
              <% end %>
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
              <ArbiterWeb.CoreComponents.Core.copy_id id={b.id} />
              <.status_chip status={b.status} />
            </li>
          </ul>

          <ArbiterWeb.CoreComponents.Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> task_path(@f, page) end}
            class={@tasks != [] && "pt-2"}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp difficulty_select_value(:none), do: "none"
  defp difficulty_select_value(d) when is_integer(d), do: Integer.to_string(d)
  defp difficulty_select_value(nil), do: ""

  defp epic_select_value(:none), do: "none"
  defp epic_select_value(id) when is_binary(id), do: id
  defp epic_select_value(nil), do: ""

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
