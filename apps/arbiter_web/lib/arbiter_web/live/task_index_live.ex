defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  closed) and offset/limit paging, newest-updated first. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.

  The "New issue" action opens an inline create form (the
  `WorkspaceIndexLive` pattern) so an operator can file an issue without
  dropping to `arb create`. It writes through the same `Issue` `:create`
  action the CLI/MCP use, so the tracker-mirroring and id-generation hooks
  apply identically, and it applies the same `Arbiter.Tasks.Dedup` check the
  REST API does (with a "Create anyway" override).

  The create itself runs in `start_async/3`: both the dedup check and
  `Issue.create`'s `CreateUpstream` hook talk to the upstream tracker over the
  network, and a LiveView must not block its own process on that. The
  `CreateUpstream` failure stash is per-process, so it is drained *inside* the
  async function — the same drain `ArbiterWeb.Api.IssueController.create/2`
  does — and surfaced as a warning rather than silently swallowed.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.Paging
  alias ArbiterWeb.TaskForm
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
     |> assign(:filters, @filters)
     |> assign(:creating, false)
     |> assign(:create_error, nil)
     |> assign(:create_params, %{})
     |> assign(:create_dup, nil)
     |> assign(:submitting, false)
     |> assign(:priority_options, TaskForm.priority_options())
     |> assign(:difficulty_options, TaskForm.difficulty_options())
     |> assign(:issue_type_options, TaskForm.issue_type_options())
     |> load_workspaces()}
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

  # ---- create ----

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(creating: true, create_error: nil, create_params: %{}, create_dup: nil)
     |> load_workspaces()}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply,
     assign(socket, creating: false, create_error: nil, create_params: %{}, create_dup: nil)}
  end

  # A submit while one is already in flight would spawn a second create.
  def handle_event("create", _params, %{assigns: %{submitting: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("create", %{"task" => params}, socket) do
    {:noreply, submit_create(socket, params, false)}
  end

  # "Create anyway" — the operator has seen the duplicate matches and wants the
  # issue filed regardless (the dashboard's `--force`). Re-submits the params
  # they already typed, which are still stashed in `:create_params`.
  def handle_event("create_force", _params, socket) do
    {:noreply, submit_create(socket, socket.assigns.create_params, true)}
  end

  # Validation that needs no I/O runs here, on the LiveView process; everything
  # that touches the DB or the tracker runs in the async task.
  defp submit_create(socket, params, force?) do
    # Keep what was typed so a rejected submit re-renders it rather than
    # blanking the form.
    socket = assign(socket, :create_params, params)

    with {:ok, title} <- fetch_title(params),
         {:ok, workspace_id} <- fetch_workspace_id(params),
         {:ok, priority} <- fetch_priority(params),
         {:ok, difficulty} <- fetch_difficulty(params) do
      attrs = %{
        title: title,
        workspace_id: workspace_id,
        priority: priority,
        difficulty: difficulty,
        issue_type: TaskForm.trimmed(params["issue_type"]) || "feature",
        description: TaskForm.trimmed(params["description"]),
        acceptance: TaskForm.trimmed(params["acceptance"])
      }

      socket
      |> assign(submitting: true, create_error: nil, create_dup: nil)
      |> start_async(:create, fn -> run_create(attrs, force?) end)
    else
      {:error, message} -> assign(socket, :create_error, message)
    end
  end

  # Runs off the LiveView process. Drains the `CreateUpstream` stash here
  # because it is per-process — draining in `handle_async/3` would read the
  # LiveView's (empty) slot and silently lose a tracker-mirror failure.
  defp run_create(attrs, force?) do
    case Dedup.check(attrs.title, attrs.workspace_id, force: force?) do
      :ok ->
        case Ash.create(Issue, attrs) do
          {:ok, task} -> {:created, task, CreateUpstream.last_error()}
          {:error, err} -> {:invalid, TaskForm.error_message(err)}
        end

      dup ->
        {:duplicate, dup}
    end
  end

  @impl true
  def handle_async(:create, {:ok, {:created, task, nil}}, socket) do
    {:noreply,
     socket
     |> assign(submitting: false, creating: false, create_error: nil)
     |> assign(create_params: %{}, create_dup: nil)
     |> put_flash(:info, "Created #{socket.assigns.issue_label} #{task.id}.")
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  # The issue is durable but the upstream mirror failed — same condition the
  # REST API answers with a 502. Say so instead of reporting a clean create.
  def handle_async(:create, {:ok, {:created, task, err}}, socket) do
    {:noreply,
     socket
     |> assign(submitting: false, creating: false, create_error: nil)
     |> assign(create_params: %{}, create_dup: nil)
     |> put_flash(
       :error,
       "Created #{task.id} locally, but the tracker mirror failed: " <>
         "#{upstream_error_text(err)} Re-link with `arb update #{task.id} --tracker-ref REF`."
     )
     |> push_navigate(to: ~p"/tasks/#{task.id}")}
  end

  def handle_async(:create, {:ok, {:duplicate, dup}}, socket) do
    {:noreply, assign(socket, submitting: false, create_dup: dup, create_error: nil)}
  end

  def handle_async(:create, {:ok, {:invalid, message}}, socket) do
    {:noreply, assign(socket, submitting: false, create_error: message)}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, submitting: false, create_error: "Create crashed: #{inspect(reason)}")}
  end

  defp upstream_error_text(%{message: message}) when is_binary(message), do: message
  defp upstream_error_text(err), do: inspect(err)

  defp dup_matches({:local_dup, matches}), do: Enum.map(matches, &{&1.id, &1.title})

  defp dup_matches({:tracker_dup, matches}),
    do: Enum.map(matches, &{Map.get(&1, :url) || Map.get(&1, :ref) || "?", Map.get(&1, :title)})

  defp dup_matches(_), do: []

  defp fetch_title(params) do
    case TaskForm.trimmed(params["title"]) do
      nil -> {:error, "Title can't be empty."}
      title -> {:ok, title}
    end
  end

  defp fetch_workspace_id(params) do
    case TaskForm.trimmed(params["workspace_id"]) do
      nil -> {:error, "Pick a workspace to file this issue in."}
      id -> {:ok, id}
    end
  end

  defp fetch_priority(params) do
    case TaskForm.parse_int(params["priority"]) do
      {:ok, nil} -> {:ok, 2}
      {:ok, priority} -> {:ok, priority}
      :error -> {:error, "Priority must be a number 0–4."}
    end
  end

  defp fetch_difficulty(params) do
    case TaskForm.parse_int(params["difficulty"]) do
      {:ok, difficulty} -> {:ok, difficulty}
      :error -> {:error, "Difficulty must be a number 0–4."}
    end
  end

  defp load_workspaces(socket) do
    workspaces =
      Workspace
      |> Ash.Query.sort(name: :asc)
      |> Ash.read()
      |> case do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, :workspaces, workspaces)
  end

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
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-clipboard-document-list"
            title={cap_plural(@issue_label)}
            count={@total_count}
            subtitle={"Every #{@issue_label}, filterable and paged. The dashboard shows only the current ones."}
          />
          <div class="flex items-center gap-2">
            <.live_badge live={@live} />
            <.button
              :if={!@creating}
              phx-click="new"
              variant="primary"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-plus" class="size-4" /> New {@issue_label}
            </.button>
          </div>
        </div>

        <section :if={@creating} class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <h2 class="font-semibold text-sm">Create an {@issue_label}</h2>

            <p :if={@workspaces == []} class="text-sm text-error">
              No workspaces exist yet — create one first at <.link
                navigate={~p"/workspaces"}
                class="link"
              >/workspaces</.link>.
            </p>

            <.form
              :if={@workspaces != []}
              for={%{}}
              as={:task}
              id="task-create-form"
              phx-submit="create"
              class="grid sm:grid-cols-2 gap-x-4"
            >
              <div class="sm:col-span-2">
                <.input
                  name="task[title]"
                  label="Title"
                  value={TaskForm.value(@create_params, "title")}
                  required
                  placeholder="Short imperative summary"
                />
              </div>
              <.input
                type="select"
                name="task[workspace_id]"
                label="Workspace"
                options={Enum.map(@workspaces, &{"#{&1.name} (#{&1.prefix})", &1.id})}
                value={TaskForm.value(@create_params, "workspace_id", List.first(@workspaces).id)}
              />
              <.input
                type="select"
                name="task[issue_type]"
                label="Type"
                options={@issue_type_options}
                value={TaskForm.value(@create_params, "issue_type", "feature")}
              />
              <.input
                type="select"
                name="task[priority]"
                label="Priority"
                options={@priority_options}
                value={TaskForm.value(@create_params, "priority", "2")}
              />
              <.input
                type="select"
                name="task[difficulty]"
                label="Difficulty"
                options={@difficulty_options}
                value={TaskForm.value(@create_params, "difficulty")}
              />
              <div class="sm:col-span-2">
                <.input
                  type="textarea"
                  name="task[description]"
                  label="Description (optional)"
                  value={TaskForm.value(@create_params, "description")}
                  rows="4"
                  placeholder="Context, scope, and anything a worker would otherwise have to guess."
                />
              </div>
              <div class="sm:col-span-2">
                <.input
                  type="textarea"
                  name="task[acceptance]"
                  label="Acceptance (optional)"
                  value={TaskForm.value(@create_params, "acceptance")}
                  rows="3"
                  placeholder="How we'll know it's done."
                />
              </div>
              <p :if={@create_error} class="sm:col-span-2 text-sm text-error">{@create_error}</p>

              <%!-- Duplicate-title warning. Advisory, not fatal: the same rule
                   the REST API answers with a 409, plus the dashboard's
                   equivalent of `--force`. --%>
              <div
                :if={@create_dup}
                id="task-create-dup"
                role="alert"
                class="sm:col-span-2 alert alert-warning py-2 mt-1 flex-col items-start gap-1"
              >
                <span class="text-sm font-medium">
                  {Dedup.message(@create_dup)} — file it anyway?
                </span>
                <ul class="text-xs font-mono list-disc list-inside">
                  <li :for={{ref, title} <- dup_matches(@create_dup)}>{ref} {title}</li>
                </ul>
              </div>

              <div class="sm:col-span-2 flex gap-2 mt-1">
                <.button
                  type="submit"
                  variant="primary"
                  class="btn btn-sm btn-primary"
                  disabled={@submitting}
                >
                  {if @submitting, do: "Creating…", else: "Create"}
                </.button>
                <.button
                  :if={@create_dup}
                  type="button"
                  phx-click="create_force"
                  class="btn btn-sm btn-warning"
                  disabled={@submitting}
                >
                  Create anyway
                </.button>
                <.button type="button" phx-click="cancel_new" class="btn btn-sm btn-ghost">
                  Cancel
                </.button>
              </div>
            </.form>
          </div>
        </section>

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
